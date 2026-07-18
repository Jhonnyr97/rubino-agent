# frozen_string_literal: true

module Rubino
  module Jobs
    module Handlers
      # Hermes-style post-turn background SKILL review (port of hermes-agent's
      # agent/background_review.py `spawn_background_review`). Replaces the old
      # DistillSkillJob (a single aux call with a DIVERGENT system prompt that
      # evicted the live KV slot, so it had to be suppressed in interactive).
      #
      # Instead of one JSON create-or-decline call, this FORKS the agent and
      # runs a real, restricted review turn:
      #   - a child session seeded with the parent's full conversation snapshot
      #     (Session::Store#copy_into), and
      #   - the parent turn's EXACT system prompt re-emitted verbatim
      #     (PromptAssembler.system_prompt_for → system_prompt_override), so the
      #     review request's prefix is BYTE-IDENTICAL to the parent turn's warm
      #     cache. The request therefore EXTENDS the warm prefix instead of
      #     busting it — no eviction, no "freeze after N turns". That is why the
      #     enqueue (Lifecycle#enqueue_post_turn_jobs) carries NO evicts-live-slot
      #     gate and runs inter-turn in the interactive REPL, exactly as Hermes.
      #
      # Tool dispatch is restricted to the skill/memory tools via
      # Rubino.with_review_toolset — the request still carries the full tools[]
      # (so the prefix stays byte-identical), but only skill/memory may execute,
      # and they run pre-approved (trusted sandboxed writes to HOME/skills + the
      # memory store) so the human-less thread never parks on an approval gate.
      #
      # The forked review AGENT decides, agentically, whether the just-finished
      # work is a reusable technique worth capturing; a trivial one-off or an
      # already-covered task simply yields no write.
      class BackgroundReviewJob
        # Ported CLOSELY from hermes-agent's _SKILL_REVIEW_PROMPT — same ACTIVE
        # stance, class-level shape, preference order, and do-NOT-capture list.
        # Only the tool references are adapted to rubino's single `skill` tool:
        # the catalogue is ALREADY in the system prompt's "## Skills" section
        # (so there is NO list/inspect call to make — that mismatch made the
        # model invent a non-existent action and leak it as text), skills are
        # read with skill(name), and writes go through skill(action: ...).
        SKILL_REVIEW_PROMPT = <<~PROMPT
          Review the conversation above and update the skill library. Be ACTIVE —
          most sessions produce at least one skill update, even if small. A pass
          that does nothing is a missed learning opportunity, not a neutral
          outcome.

          Target shape of the library: CLASS-LEVEL skills, each with a rich
          SKILL.md and a references/ directory for session-specific detail. Not a
          long flat list of narrow one-session-one-skill entries. This shapes HOW
          you update, not WHETHER you update.

          You have ONE tool for this — the `skill` tool. The skills that already
          exist are listed under "## Skills" in your system prompt (there is no
          separate "list" step; if that section is empty, none exist yet). To
          inspect a skill before changing it, load it (the tool's "load" action
          with its name). To save your learning, call the tool with one of its
          write actions — "patch", "edit", "write_file", or "create" — described
          below. Emit these as real tool calls, not as text.

          Signals to look for (any one warrants action):
            • The user corrected your style, tone, format, verbosity, workflow,
              or sequence of steps. Frustration ("stop doing X", "this is too
              verbose", "you always do Y and I hate it") or an explicit "remember
              this" are FIRST-CLASS skill signals — embed the lesson in the skill
              that governs that class of task so the next session starts fixed.
            • A non-trivial technique, fix, workaround, debugging path, or
              tool-usage pattern emerged that a future session would benefit from.
            • A skill that was loaded or consulted turned out wrong, missing a
              step, or outdated — patch it NOW.

          Preference order — prefer the earliest that fits, but pick one when a
          signal above fired:
            1. UPDATE A SKILL that already covers this territory. For a small
               change (add a pitfall, a step, broaden a trigger) use the tool's
               "patch" action, giving the skill name, the exact existing text,
               and its replacement. For a major overhaul use the "edit" action
               with the skill name and the full new body. Do NOT create a
               near-duplicate of a skill that already exists.
            2. ADD A SUPPORT FILE under an existing skill with the tool's
               "write_file" action — a file_path starting references/,
               templates/, or scripts/, plus its content — for session-specific
               detail, a starter template, or a re-runnable script. Add a
               one-line pointer to it in the skill's SKILL.md.
            3. CREATE A NEW CLASS-LEVEL SKILL when nothing covers the class,
               using the "create" action with a name, a one-line
               "Use when <trigger-class> — …" description (trigger-focused, not
               task-labeled — "Use when debugging timeouts in Rack apps", not
               "Debug timeouts"), and a prescriptive body that includes
               "## When to use" and "## Don't use for" counter-triggers.
               The name MUST be class-level — NOT a PR number, error string,
               codename, library-alone name, or "fix-X / debug-Y" session
               artifact. If the name only makes sense for today's task, fall
               back to (1) or (2).

          Bundled skills are protected — do not try to edit them; capture a new
          skill or update a user-authored one instead.

          Do NOT capture (these harden into constraints that bite you later):
            • Environment-dependent failures: missing binaries, fresh-install
              errors, path mismatches, "command not found", unconfigured
              credentials. The user can fix these — they are not durable rules.
            • Negative claims about tools ("X is broken", "cannot use Y"). If a
              tool failed because of setup state, capture the FIX, never "this
              tool does not work".
            • Session-specific transient errors that resolved before the end.
            • One-off task narratives ("summarize today's news", "analyze this
              PR") — not a class of work that warrants a skill.

          "Nothing to save." is a real option but should NOT be the default. If
          the session ran smoothly with no correction and produced no new
          technique, say "Nothing to save." and stop. Otherwise, act.
        PROMPT

        # The memory half of the review (the SINGLE automatic memory-extraction
        # path now that the structured aux-LLM extractor is gone). Same
        # warm-prefix fork, same restricted toolset — just the `memory` tool
        # instead of `skill`. The forked agent decides agentically which durable
        # facts from the conversation are worth persisting; the existing memories
        # are ALREADY in the system prompt, so it never re-writes them.
        MEMORY_REVIEW_PROMPT = <<~PROMPT
          Review the conversation above and persist any DURABLE facts worth
          recalling in a FUTURE session, using the `memory` tool. Emit real tool
          calls, not text.

          For each durable fact, call the tool with action=add and the right
          target:
            • target=user — a stable fact about the USER: their name, identity,
              role, or a lasting preference/convention they hold ("I prefer X",
              "always do Y", "call me Z").
            • target=project — a durable fact about THIS project/codebase: its
              stack, conventions, layout, build/test commands, or an
              architectural decision that will still be true next session.
            • target=memory — anything else durable that doesn't fit the two
              slots above.

          Rules:
            • ONE atomic fact per call — make separate calls for separate facts so
              each can be superseded or forgotten independently.
            • The facts you already saved are listed in your system prompt (user
              profile, project context, and relevant memories). Do NOT re-write a
              fact that is already there.
            • Skip transient or environment-dependent details: one-off task state,
              a value that only mattered this session, missing binaries, path
              mismatches, "command not found", unconfigured credentials. Those are
              not durable rules.
            • If a previously-stored fact was contradicted this session, use
              action=replace to update it (substring match on the old text).

          "Nothing durable to save." is a valid outcome — if the conversation
          produced no lasting fact about the user or project, say so and stop.
        PROMPT

        # Both surfaces in ONE turn (port of Hermes' _COMBINED_REVIEW_PROMPT).
        # Used when skill distillation AND memory mining are both due — spelling
        # out the skill/memory boundary in a single pass makes the model route a
        # style/workflow correction to a SKILL and a durable identity fact to
        # MEMORY, instead of the two separate turns collapsing everything into one
        # bucket (verified: ~1.0 skill + ~1.0 memory per run vs ~0.33 / ~0.0).
        COMBINED_REVIEW_PROMPT = <<~PROMPT
          Review the conversation above and update two things.

          **Memory** (the `memory` tool): who the user is. Did the user reveal
          persona, preferences, personal details, environment, or a durable
          expectation about how you should behave? Save durable facts — target=user
          for identity/preferences, target=project for durable codebase facts.

          **Skills** (the `skill` tool): how to do this class of task. Be ACTIVE —
          most sessions produce at least one skill update, even a small one.

          Signals that warrant a SKILL update (any one is enough):
            • The user corrected your style, tone, format, verbosity, workflow, or
              approach. Frustration ("stop doing X", "don't format like this",
              "always do Y") is a FIRST-CLASS SKILL signal, not just a memory one —
              embed the lesson in the skill that governs that task so the next
              session starts already fixed.
            • A non-trivial technique, fix, workaround, or debugging path emerged.
            • A consulted skill turned out wrong or outdated — patch it now.

          Preference order for skills: (1) "patch"/"edit" an existing relevant
          skill (skills are listed under "## Skills" in your system prompt); (2)
          add a support file via "write_file"; (3) "create" a new CLASS-LEVEL skill
          (kebab-case name, a "Use when <trigger-class> — …" trigger-focused
          description, and a markdown body with "## When to use" and
          "## Don't use for" sections) when nothing covers it.

          Boundary: Memory says "WHO the user is and the current state"; skills say
          "HOW to do this class of task for this user". When the user complains
          about HOW you handled a task, the SKILL that governs that task must carry
          the lesson — memory alone is not enough. A style/workflow correction
          belongs in a skill body.

          Do NOT capture as skills: environment-dependent failures ("command not
          found", missing binaries, unconfigured credentials), negative tool claims,
          or one-off task narratives. Emit real tool calls, not text. Act on
          whichever dimension has real signal; say "Nothing to save." only if
          neither does — but don't reach for that as a default.
        PROMPT

        def perform(payload)
          session_id = payload[:session_id] || payload["session_id"]
          return unless session_id

          # Which halves to run: an array of surface strings ("skill" / "memory").
          # nil ⇒ both. Lets a caller invoke ONE surface inline (e.g. the one-shot
          # session-end fork requests both; a targeted caller can request just
          # "memory"). Intersected with the config-enabled surfaces in #run_review.
          surfaces = payload[:surfaces] || payload["surfaces"]

          # The LIVE runtime provider the parent turn ran on (the CLI --provider
          # override), threaded from Lifecycle#enqueue_post_turn_jobs. nil ⇒ no
          # override was in effect, so the config default applies (see #run_review).
          provider = payload[:provider] || payload["provider"]

          parent = Session::Repository.new.find(session_id)
          return unless parent

          messages = Session::Store.new.for_session(session_id)
          return unless succeeded?(messages)

          # The parent turn's captured system prompt is what pins the review's
          # prefix to the warm cache. Without it we cannot guarantee coherence
          # (e.g. the very first turn before any capture) — skip this round
          # rather than risk an eviction; the next interval will have it.
          system_prompt = Context::PromptAssembler.system_prompt_for(session_id)
          return unless system_prompt

          run_review(parent, system_prompt, surfaces, provider)
        rescue StandardError => e
          Rubino.logger.warn(event: "jobs.background_review.error",
                             error_class: e.class.name, message: e.message)
          nil
        end

        private

        # A turn "succeeded" when it produced a non-empty final assistant answer
        # (mirrors Hermes gating on final_response present). No answer ⇒ nothing
        # worth reviewing.
        def succeeded?(messages)
          messages.reverse.any? { |m| m.role == "assistant" && !m.content.to_s.strip.empty? }
        end

        def run_review(parent, system_prompt, requested_surfaces = nil, live_provider = nil)
          # Intersect the config-enabled surfaces with what the caller asked for.
          # A nil request means "whatever config enables" (the queue/polishing
          # path); an explicit array narrows it (the inline callers). Each half
          # runs only when BOTH its config gate is on AND it was requested.
          requested = requested_surfaces && Array(requested_surfaces).to_set(&:to_s)
          skills_on = Rubino.configuration.skills_auto_distill? &&
                      (requested.nil? || requested.include?("skill"))
          memory_on = Rubino.configuration.memory_auto_extract? &&
                      (requested.nil? || requested.include?("memory"))
          return unless skills_on || memory_on

          # The request still carries the FULL tools[] (so the prefix stays
          # byte-identical to the parent turn's warm cache), but only these tools
          # may actually execute — pre-approved sandboxed writes to HOME/skills +
          # the memory store, so the human-less thread never parks on approval.
          allowed = []
          allowed << "skill" if skills_on
          allowed << "memory" if memory_on

          child = fork_child(parent)
          runner = Agent::Runner.new(
            session_id: child[:id],
            model_override: parent[:model],
            # Inherit the parent turn's LIVE runtime provider (Hermes'
            # _current_main_runtime): the CLI `--provider` override when the live
            # conversation had one, else the config default. `live_provider` is
            # that override, threaded from Lifecycle#enqueue_post_turn_jobs; the
            # config `model.provider` is the fallback. We must NOT use only the
            # config default (it IGNORES --provider, so a `--provider gateway`
            # turn misrouted the review to the native default e.g. "deepseek",
            # which has no gateway credentials and fails "Missing <x>_api_key" —
            # then the whole retry/backoff ladder ran and, inline, HUNG shutdown).
            # Matching the live provider also keeps the review on the SAME server
            # slot as the live turn — the point of the byte-identical warm prefix.
            provider_override: live_provider || Rubino.configuration.dig("model", "provider"),
            ui: UI::Null.new,
            interactive: false,
            announce_session: false,
            session_source: "review",
            system_prompt_override: system_prompt,
            # Emit on the process bus so the CLI's created-skill subscription
            # surfaces "✓ created skill …" to the user, same as a foreground
            # skill(create) does.
            event_bus: Rubino.event_bus
          )

          # This fork is the SINGLE extraction mechanism for BOTH surfaces: the
          # structured aux-LLM memory extractor was deleted, so memory mining now
          # rides the same warm-prefix review as skills.
          #
          # When BOTH surfaces are due, run ONE combined turn (Hermes'
          # _COMBINED_REVIEW_PROMPT) rather than two sequential focused turns.
          # A/B against the local model showed the combined turn both distils a
          # skill AND mines a memory fact reliably (~1.0 each per run), while two
          # separate turns under-produced (skills ~0.33, memory ~0.0): with the
          # skill/memory boundary spelled out in ONE prompt the model routes a
          # style/workflow correction to a SKILL and a durable identity fact to
          # MEMORY instead of collapsing everything into one bucket — and it is
          # also HALF the cost (one fork turn, not two) on a slow local backend.
          # A single enabled surface keeps its own focused prompt.
          # Bind the PARENT session id as the memory source so facts mined by
          # this disposable child review session are attributed to the driving
          # parent, not the throwaway child. ToolExecutor respects an existing
          # binding and skips its own override when one is already set.
          Rubino.with_memory_source_session_id(parent[:id]) do
            Rubino.with_review_toolset(allowed) do
              if skills_on && memory_on
                runner.run!(COMBINED_REVIEW_PROMPT)
              elsif skills_on
                runner.run!(SKILL_REVIEW_PROMPT)
              else
                runner.run!(MEMORY_REVIEW_PROMPT)
              end
            end
          end
        ensure
          destroy_child(child) if child
        end

        # Fork a disposable child session seeded with the parent's full history
        # (source "review" keeps it out of the user-facing /sessions picker, like
        # subagent sessions). Mirrors Runner#fork_busy_session.
        def fork_child(parent)
          repo = Session::Repository.new
          store = Session::Store.new
          child = repo.create(
            source: "review",
            model: parent[:model],
            provider: parent[:provider],
            title: parent[:title],
            parent_session_id: parent[:id],
            cwd: parent[:cwd]
          )
          store.copy_into(child[:id], store.for_session(parent[:id]))
          repo.update(child[:id], message_count: store.count(child[:id]))
          child
        end

        def destroy_child(child)
          Session::Repository.new.destroy!(child[:id])
        rescue StandardError => e
          Rubino.logger.warn(event: "jobs.background_review.cleanup_failed",
                             error_class: e.class.name, message: e.message)
          nil
        end
      end
    end
  end
end

# Register the handler (mirrors DistillSkillJob). Jobs::Registry also resolves
# it lazily via Handlers.const_get, but registering here keeps parity.
Rubino::Jobs::Registry.register(
  "BackgroundReviewJob", Rubino::Jobs::Handlers::BackgroundReviewJob
)
