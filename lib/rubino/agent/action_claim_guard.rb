# frozen_string_literal: true

module Rubino
  module Agent
    # Closes the #1 trust-killer: the model ENDS a turn asserting it did or will
    # do something ("Running the tests now", "Saved the file", "Changed
    # directory") with ZERO tool calls, so a fabricated success reaches the user.
    #
    # The structured tool-call channel is the ONLY thing that advances state. A
    # text-only turn whose prose claims an action against a tool rubino exposes
    # is, by construction, a claim with nothing behind it. We do not trust it.
    #
    # Two intents, two outcomes:
    #
    #   1. cd / "change directory" — rubino has NO cd tool, so the claim can NEVER
    #      be true. We do not reflect (a reflection would just invite the model to
    #      claim it again); we REWRITE the final answer with an honest message
    #      explaining how to actually change the workspace (/add-dir or relaunch).
    #
    #   2. any other action verb (run/test/save/write/edit/create/delete/move…)
    #      mapped to a tool rubino DOES expose — we REFLECT one corrective turn
    #      ("you said you would <X> but issued no tool call; call the tool now or
    #      say you cannot and why"), capped at MAX_REFLECTIONS (aider's
    #      reflected_message pattern, capped). After the cap we stop honestly
    #      rather than surface the fabricated "done".
    #
    # Deliberately conservative — it must never nag a legitimate text answer:
    #   * Only fires when the WHOLE turn ran zero tools AND zero denied tools.
    #     A turn that ran (or had denied) any tool is the model acting/recovering,
    #     not fabricating; its closing prose is a real summary.
    #   * The verb must be asserted as the assistant's OWN action in the
    #     present-progressive / just-completed / immediate-future ("I'll run…",
    #     "Running…", "I ran…", "Saved…", "Done — created…"), not described
    #     ("you can run…", "to run the tests…", "the test command is…").
    #   * A turn that ASKS the user something (ends on a question) is a legitimate
    #     clarify, not a fabricated completion — left alone.
    class ActionClaimGuard
      # aider caps reflected_message at 3; the same ceiling here. After this many
      # corrective turns we stop and surface the model's last text honestly
      # rather than loop forever against a model that won't call the tool.
      MAX_REFLECTIONS = 3

      # Verbs that imply a state-changing action the agent performs THROUGH a
      # tool. Each maps to the tool name(s) that would actually carry it out, so
      # we only reflect when rubino actually exposes a way to do the claimed
      # thing (no point nagging "I searched the web" if web tools are disabled).
      ACTION_TOOLS = {
        "run" => %w[shell ruby test git github],
        "ran" => %w[shell ruby test git github],
        "execute" => %w[shell ruby],
        "executed" => %w[shell ruby],
        "test" => %w[test shell],
        "tested" => %w[test shell],
        "save" => %w[write edit multi_edit patch],
        "saved" => %w[write edit multi_edit patch],
        "write" => %w[write edit multi_edit patch],
        "wrote" => %w[write edit multi_edit patch],
        "edit" => %w[edit multi_edit write patch],
        "edited" => %w[edit multi_edit write patch],
        "create" => %w[write edit multi_edit],
        "created" => %w[write edit multi_edit],
        "delete" => %w[shell],
        "deleted" => %w[shell],
        "remove" => %w[edit multi_edit shell write],
        "removed" => %w[edit multi_edit shell write],
        "move" => %w[shell],
        "moved" => %w[shell],
        "rename" => %w[shell edit multi_edit],
        "renamed" => %w[shell edit multi_edit],
        "install" => %w[shell],
        "installed" => %w[shell],
        "commit" => %w[git shell],
        "committed" => %w[git shell],
        "push" => %w[git shell],
        "pushed" => %w[git shell],
        "fetch" => %w[web_fetch shell git],
        "fetched" => %w[web_fetch shell git]
      }.freeze

      # File/state MUTATION verbs — the highest-cost class for a coding agent.
      # A toolless turn that asserts ANY of these as the assistant's own past
      # action ("Updated both methods", "Added the docstring", "I removed mode()")
      # has, by construction, changed nothing on disk. Unlike the verbs above,
      # these are matched ANYWHERE in the message (not just sentence-initial or
      # inside a completion window) and PRIORITISED over a trailing future-intent
      # verb, so a message that bundles a fabricated edit-claim with a "then I'll
      # run the tests" is challenged on the EDIT, not on the trailing run. Each
      # maps to the write-family tool(s) that would actually carry it out, so the
      # claim is only challenged when rubino actually exposed a way to mutate.
      MUTATION_TOOLS = {
        "edited" => %w[edit multi_edit write patch],
        "wrote" => %w[write edit multi_edit patch],
        "written" => %w[write edit multi_edit patch],
        "updated" => %w[edit multi_edit write patch],
        "created" => %w[write edit multi_edit],
        "added" => %w[edit multi_edit write patch],
        "removed" => %w[edit multi_edit write patch shell],
        "saved" => %w[write edit multi_edit patch],
        "modified" => %w[edit multi_edit write patch],
        "renamed" => %w[shell edit multi_edit],
        "deleted" => %w[shell edit multi_edit write],
        "applied" => %w[patch edit multi_edit write],
        "changed" => %w[edit multi_edit write patch],
        "replaced" => %w[write edit multi_edit patch],
        "inserted" => %w[edit multi_edit write patch],
        "appended" => %w[edit multi_edit write patch],
        "fixed" => %w[edit multi_edit write patch]
      }.freeze

      # The assistant asserts a mutation as its OWN completed action — past-tense
      # mutation verb in a first-person OR a bare/completion narration, ANYWHERE
      # in the text. Built per-verb from MUTATION_TOOLS' keys (which are already
      # the past/participle surface forms). Matches "I updated…", "I've added…",
      # "Updated both methods", "Done. Added the docstring", "✓ wrote the file",
      # "- removed mode()". Deliberately past-tense only: a bare future "I'll
      # update…" with a real tool call is handled by tool_count > 0; a future
      # intent with NO tool call is still a fabrication and is also caught here
      # via the first-person future framing below.
      # Three alternatives, no interspersed comments (a `#` mid-concatenation
      # would break the `\` line-continuation into a bare `(?:`):
      #   1. first-person past / completed — "I updated", "I've added",
      #      "I just wrote", "we removed", "now i updated".
      #   2. first-person immediate-future with NO tool call — still a
      #      fabrication — "I'll update…", "let me add…", "I will write…".
      #   3. bare sentence-initial / list-item / post-completion past form —
      #      "Updated both methods", "Added the docstring", "Done. Wrote the
      #      file", "✓ removed mode()", "- created config.rb".
      MUTATION_SELF_SRC =
        "(?:" \
        '\b(?:i|we|i\s?\'?ve|we\s?\'?ve|i\s+have|we\s+have|i\s+just|now\s+i)\b' \
        '\s+(?:just\s+|now\s+|already\s+|go\s+ahead\s+and\s+)?(VERB)\b' \
        '|\b(?:i\s?\'?ll|i\s+will|let\s+me|i\s?\'?m\s+going\s+to|i\s+am\s+going\s+to|' \
        'going\s+to|about\s+to)\b\s+(?:just\s+|now\s+|go\s+ahead\s+and\s+)?(VERBBASE)\b' \
        '|(?:\A|[.!?\n]\s*|^[-*]\s*|' \
        '(?:\b(?:done|finished|complete|completed|ok|okay)\b|✓|✅|all\s+(?:set|done))[^.!?\n]{0,30}?)' \
        '(VERB)\b' \
        ")"

      # base form of each mutation verb (for the immediate-future framing above):
      # "I'll update", "let me add". Keyed by the past form stored in
      # MUTATION_TOOLS so the alternation stays in lockstep with the tool map.
      MUTATION_BASE = {
        "edited" => "edit", "wrote" => "write", "written" => "write",
        "updated" => "update", "created" => "create", "added" => "add",
        "removed" => "remove", "saved" => "save", "modified" => "modify",
        "renamed" => "rename", "deleted" => "delete", "applied" => "apply",
        "changed" => "change", "replaced" => "replace", "inserted" => "insert",
        "appended" => "append", "fixed" => "fix"
      }.freeze

      # State-RESULT phrasing — a fabricated mutation dressed as a fact about the
      # file/state rather than as an action verb: "README.md now contains 'API
      # v2'", "the file now has the import", "X is now set to 5", "the contents
      # now read …", "it now reflects the change". No action verb at all, so the
      # verb-based matchers above miss it entirely (this was the r5c NEW-1 hole).
      # We require a "now" + a state predicate so we don't trip on a plain
      # description ("the file contains a bug"). Backed by the write-family tools.
      STATE_RESULT = Regexp.new(
        '\bnow\s+(?:contains|has|holds|includes|reads|reflects|shows|' \
        'looks\s+like|points\s+to)\b' \
        '|\b(?:is|are|reads)\s+now\s+(?:set\s+to|equal\s+to|)' \
        '|\bnow\s+(?:set\s+to|equal\s+to)\b' \
        '|\bthe\s+(?:file|contents?|method|function|class|line|import|' \
        'docstring|code|config(?:uration)?)\b[^.!?\n]{0,40}?\bnow\b' \
        '|\b(?:contents?|file|value|content)\b[^.!?\n]{0,30}?\b(?:is|are)\s+now\b',
        Regexp::IGNORECASE
      )

      # The write-family tools any mutation/state-result claim needs on offer for
      # the guard to challenge it — no point challenging "the file now contains X"
      # if rubino has no way to write at all this turn.
      WRITE_FAMILY = %w[write edit multi_edit patch].freeze

      # base verb => [progressive, past] surface forms. Stored explicitly rather
      # than derived so English irregulars (run→running→ran, write→writing→wrote)
      # are correct. Fuels the bare-lead / completion-lead / first-person matches.
      SURFACE_FORMS = {
        "run" => %w[running ran], "ran" => %w[running ran],
        "write" => %w[writing wrote], "wrote" => %w[writing wrote],
        "save" => %w[saving saved], "saved" => %w[saving saved],
        "edit" => %w[editing edited], "edited" => %w[editing edited],
        "create" => %w[creating created], "created" => %w[creating created],
        "delete" => %w[deleting deleted], "deleted" => %w[deleting deleted],
        "remove" => %w[removing removed], "removed" => %w[removing removed],
        "move" => %w[moving moved], "moved" => %w[moving moved],
        "rename" => %w[renaming renamed], "renamed" => %w[renaming renamed],
        "commit" => %w[committing committed], "committed" => %w[committing committed],
        "push" => %w[pushing pushed], "pushed" => %w[pushing pushed],
        "fetch" => %w[fetching fetched], "fetched" => %w[fetching fetched],
        "install" => %w[installing installed], "installed" => %w[installing installed],
        "execute" => %w[executing executed], "executed" => %w[executing executed],
        "test" => %w[testing tested], "tested" => %w[testing tested]
      }.freeze

      # First-person assertion that the action is happening / happened / is about
      # to happen — NOT a description offered to the user. We require one of these
      # framings immediately around a tracked verb so "you can run the tests"
      # never trips, but "I'll run the tests", "running the tests now",
      # "I ran the tests", "saved the file" do.
      #   subject framings: "i", "i'll", "i've", "i have", "let me", "i'm",
      #                     "i am", "i will", "i just", "going to", "about to"
      #   bare-progressive / bare-past at sentence start: "running…", "saved…"
      #   "i'll RUN", "i RAN", "let me SAVE" — the VERB placeholder is filled per
      #   call. Built from a String (not a regex literal) so the path/comment
      #   slashes elsewhere in this file never collide with the regex delimiter.
      FIRST_PERSON_VERB_SRC =
        '(?:\b(?:i\s?\'?ll|i\s?\'?ve|i\s+have|i\s+will|i\s+just|i\s?\'?m|i\s+am|' \
        'let\s+me|going\s+to|about\s+to|now\s+i|i)\b\s+' \
        '(?:just\s+|now\s+|go\s+ahead\s+and\s+)?)(VERB)\w*'

      # Bare sentence-initial progressive/past at the start, after a sentence end,
      # or as a list item: "Running the suite now.", "Saved to foo.py and ran
      # it.", "Created the file." — a common MiniMax-M3 narration with no "I".
      BARE_LEAD_VERB_SRC = '(?:\A|[.!?\n]\s*|^[-*]\s*)(VERBING)\b'

      # A completion marker ("done", "✓", "all set", "all done", "finished")
      # immediately before a past/progressive verb form — "Done — created the
      # file.", "✓ saved.", "All set, removed mode()." — is the model declaring
      # the work finished. The verb may sit up to ~20 non-period chars after.
      COMPLETION_LEAD_SRC =
        '(?:\b(?:done|finished|complete|completed)\b|✓|✅|all\s+(?:set|done))' \
        '[^.!?\n]{0,20}?\b(VERBING)\b'

      # cd / change-directory intent. rubino has no cd tool, so ANY first-person
      # claim to change the working directory is unfulfillable — handled
      # separately (honest rewrite, never a reflection). "cd /path", "cd ~",
      # "changed the working directory", "switched to the folder", "moved into".
      CD_INTENT = Regexp.new(
        "(?:" \
        '\bcd\s+[~/.]' \
        '|\bchang(?:e|ed|ing)\b[^.\n]{0,40}\b(?:working\s+)?(?:dir(?:ectory)?|cwd|folder|workspace)\b' \
        '|\bswitch(?:ed|ing)?\b[^.\n]{0,40}\b(?:to\s+the\s+)?(?:dir(?:ectory)?|cwd|folder)\b' \
        '|\bmov(?:e|ed|ing)\s+(?:in)?to\s+(?:the\s+)?[~.][\w./-]*' \
        ")",
        Regexp::IGNORECASE
      )

      # The text plainly admits the action did NOT / cannot happen — an honest
      # non-completion, not a fabricated "done". A bare "can't"/"unable" anywhere
      # in the answer is enough; this only EXEMPTS, never accuses, so a generous
      # match is safe.
      INABILITY = Regexp.new(
        '\b(?:can\s?\'?t|cannot|could\s?n\'?t|unable\s+to|won\s?\'?t\s+be\s+able|' \
        'don\s?\'?t\s+have|do\s+not\s+have|no\s+(?:such|test|way\s+to)|' \
        'not\s+able\s+to|wasn\s?\'?t\s+able|isn\s?\'?t\s+(?:a|any)|there\s+(?:is|are)\s+no)\b',
        Regexp::IGNORECASE
      )

      # Build a guard for one turn. `exposed_tool_names` is the set of tool names
      # the model actually had this turn (Loop's @turn_tools) — we only reflect a
      # verb whose backing tool was on offer.
      def initialize(exposed_tool_names:)
        @exposed = Array(exposed_tool_names).map(&:to_s).uniq.freeze
      end

      # The corrective user message injected when a tracked action verb appears in
      # a toolless turn. Names the offending claim so the model self-corrects.
      def reflection_message(claimed_verb)
        "You stated you #{claimed_verb} but issued NO tool call, so nothing " \
          "actually happened — that text is not a real result and the file is " \
          "unchanged on disk. Do ONE of two things now: (a) make the actual tool " \
          "call to carry it out, or (b) if you cannot (missing info, blocked, " \
          "denied, or no such capability), say plainly that you did NOT do it and " \
          "explain why. Do NOT restate that it is done."
      end

      # The honest answer that REPLACES a fabricated "I changed the directory"
      # final turn. rubino genuinely cannot cd, so we tell the truth and point at
      # the real mechanisms instead of letting the model claim a no-op.
      CD_HONEST_ANSWER =
        "I can't change my working directory — I have no `cd` tool, and each command " \
        "runs from the session's workspace root, so a `cd` would not persist anyway. " \
        "To work against another directory, either add it with `/add-dir <path>` " \
        "(grants access this session) or relaunch rubino from that directory. " \
        "If you want, tell me the path and I'll run commands against it explicitly " \
        "(e.g. by passing the full path to each command)."

      # The verdict for a finished, TEXT-ONLY turn.
      #
      #   tool_count   — tools that actually ran this turn (Loop's @tool_count)
      #   denied_count — tools the user denied this turn (Loop's @denied_count)
      #   content      — the assistant's final text
      #
      # Returns one of:
      #   nil            — no fabrication detected; surface the text as-is.
      #   [:cd, msg]     — replace the final answer with the honest cd message.
      #   [:reflect, vb] — reflect a corrective turn; `vb` is the claimed verb.
      #
      # The Loop decides what to do with each (rewrite vs re-enter the loop), and
      # owns the MAX_REFLECTIONS cap.
      def evaluate(content:, tool_count:, denied_count:)
        text = content.to_s
        return nil if text.strip.empty?
        # The model DID act (or was denied) this turn — its closing prose is a
        # real summary / recovery, not a fabrication. Never nag those.
        return nil unless tool_count.to_i.zero? && denied_count.to_i.zero?
        # A turn that ends by asking the user is a legitimate clarify, not a
        # claimed completion.
        return nil if asks_user?(text)

        return [:cd, CD_HONEST_ANSWER] if cd_intent?(text)

        # The model already owned up that it could NOT do the thing ("I can't
        # run it because…", "unable to", "there is no test file"). An action
        # verb in that sentence is honest framing, not a fabricated success —
        # don't nag it.
        return nil if honest_inability?(text)

        # HIGHEST-COST class first: a fabricated file/state MUTATION ("Updated
        # both methods", "Added the docstring", "README now contains 'API v2'")
        # anywhere in the message. Prioritised over the trailing-intent verb
        # below so a message that bundles a fake edit-claim with a "then I'll run
        # the tests" is challenged on the EDIT, not the trailing run (r5c B1).
        mutation = fabricated_mutation(text)
        return [:reflect, mutation] if mutation

        verb = fabricated_action_verb(text)
        return [:reflect, verb] if verb

        nil
      end

      private

      def honest_inability?(text)
        INABILITY.match?(text)
      end

      # The text claims to have changed the working directory — and rubino can't.
      def cd_intent?(text)
        return false unless CD_INTENT.match?(text)

        # Only when framed as the assistant's own action / completion, not as
        # advice to the user ("you can cd into …", "run cd /x yourself").
        first_person_anywhere?(text) || CD_INTENT.match?(leading_clause(text))
      end

      # The first tracked action verb the text asserts as the assistant's own
      # doing, whose backing tool rubino actually exposed this turn. nil when none.
      def fabricated_action_verb(text)
        ACTION_TOOLS.each do |verb, tools|
          next unless tools.any? { |t| @exposed.include?(t) }
          next unless asserts_verb?(text, verb)

          return "would #{verb}"
        end
        nil
      end

      # The first fabricated file/state MUTATION the toolless turn asserts, as a
      # human-readable claim phrase for the reflection ("updated the file",
      # "added the docstring", "the file now contains that"). Fires on:
      #   * a past-tense mutation verb asserted as the assistant's own action
      #     ANYWHERE in the message (not just sentence-initial), or
      #   * a state-RESULT phrasing ("X now contains …", "the file now has …").
      # Gated on a write-family tool being exposed and on the claim NOT being
      # 2nd-person advice ("you should add…", "you can write…", "to update…").
      # nil when the turn makes no fabricated mutation claim.
      def fabricated_mutation(text)
        return nil unless WRITE_FAMILY.any? { |t| @exposed.include?(t) }
        return nil if advice_only?(text)

        MUTATION_TOOLS.each do |past, tools|
          next unless tools.any? { |t| @exposed.include?(t) }
          next unless asserts_mutation?(text, past)

          return "#{past} the file"
        end

        # State-result phrasing with no action verb at all ("README now contains
        # 'API v2'", "the file now has the import") — a mutation dressed as fact.
        return "left the file in the state you described" if STATE_RESULT.match?(text)

        nil
      end

      # True when `past` (an already-past/participle mutation form) is asserted as
      # the assistant's OWN completed (or unfulfilled-future) mutation anywhere in
      # the text. Built from MUTATION_SELF_SRC with the past form and its base
      # form (for the "I'll <base>…" future framing) substituted in.
      def asserts_mutation?(text, past)
        base = MUTATION_BASE.fetch(past, past)
        src = MUTATION_SELF_SRC.gsub("VERBBASE", Regexp.escape(base))
                               .gsub("VERB", Regexp.escape(past))
        Regexp.new(src, Regexp::IGNORECASE).match?(text)
      end

      # The whole message is 2nd-person ADVICE / a how-to, not a 1st-person
      # claim — "you should add the import", "you can write it with…", "to update
      # the file, use the edit tool". A mutation verb in that framing is help
      # text, not a fabricated completion, so the guard must leave it alone. We
      # only treat it as advice when there is NO competing first-person claim, so
      # "I updated it; you can run it" is still challenged.
      def advice_only?(text)
        return false if /\b(?:i|we)\b\s*'?(?:ll|ve|m)?\b/i.match?(text) &&
                        first_person_anywhere?(text)

        /\byou\s+(?:can|could|should|may|might|will|need\s+to|have\s+to|want\s+to)\b/i
          .match?(text) ||
          /\bto\s+\w+[^.!?\n]{0,40}?,?\s*use\s+the\b/i.match?(text)
      end

      # True when `verb` appears in a first-person "I'll/I just/now" framing OR as
      # a bare sentence-initial progressive/past — the narration shapes that mean
      # "I am doing / did this", as opposed to describing it to the user.
      def asserts_verb?(text, verb)
        # The verb plus all its surface forms (write/writing/wrote/written via
        # the union) — so "i've written", "i ran", "i'm saving" all match the
        # first-person framing, not just the dictionary form.
        alt = verb_alternation(verb)

        fp = Regexp.new(FIRST_PERSON_VERB_SRC.sub("VERB", alt), Regexp::IGNORECASE)
        return true if fp.match?(text)

        # Sentence-initial / list-item progressive-or-past: "Running…", "Saved…".
        bare = Regexp.new(BARE_LEAD_VERB_SRC.sub("VERBING", verbings_for(verb)),
                          Regexp::IGNORECASE)
        return true if bare.match?(text)

        # Completion-lead narration: "Done — created the file.", "✓ saved.",
        # "All set, removed mode()." A done/✓/all-set marker immediately before a
        # past/progressive form is the model declaring the work finished.
        lead = Regexp.new(COMPLETION_LEAD_SRC.sub("VERBING", verbings_for(verb)),
                          Regexp::IGNORECASE)
        lead.match?(text)
      end

      # The regex-source alternation of a verb and every surface form we track for
      # it (run|running|ran, write|writing|wrote|written, …). Used to match the
      # verb in a first-person framing regardless of tense.
      def verb_alternation(verb)
        forms = [verb] + SURFACE_FORMS.fetch(verb, ["#{verb}ing", "#{verb}ed"])
        # write→written participle that the regular -ed/-ing forms miss.
        forms << "written" if %w[write wrote].include?(verb)
        Regexp.union(forms.uniq).source
      end

      # The surface forms that begin a bare narration sentence for a given base
      # verb: the bare verb (sentence-initial imperative-as-claim "Run the tests
      # now."), its progressive ("Running…"), and its past ("Ran…"/"Saved…").
      # Stored explicitly rather than derived so English irregulars (run→running,
      # write→writing→wrote) are correct.
      def verbings_for(verb)
        forms = [verb] + SURFACE_FORMS.fetch(verb, ["#{verb}ing", "#{verb}ed"])
        forms << "written" if %w[write wrote].include?(verb)
        Regexp.union(forms.uniq).source
      end

      def first_person_anywhere?(text)
        /\b(?:i\s?'?ll|i\s?'?ve|i\s+have|i\s+will|i\s+just|i\s?'?m|i\s+am|let\s+me|
            i\s+chang|i\s+switch|i\s+mov|now\s+i)\b/ix.match?(text)
      end

      # The first sentence/clause, where a bare "Changed directory." lead-in lives.
      def leading_clause(text)
        text.strip[/\A[^.!?\n]{0,120}/].to_s
      end

      # The text ends by asking the user (a trailing question) — a legitimate
      # clarify, not a fabricated completion. We look only at the tail so a
      # rhetorical "?" earlier in a long answer doesn't exempt a fabrication.
      def asks_user?(text)
        tail = text.strip[-160..] || text.strip
        tail.rstrip.end_with?("?")
      end
    end
  end
end
