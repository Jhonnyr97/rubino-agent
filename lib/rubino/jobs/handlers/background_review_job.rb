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
               match-on-sight description, and a prescriptive body. The name MUST
               be class-level — NOT a PR number, error string, codename,
               library-alone name, or "fix-X / debug-Y" session artifact. If the
               name only makes sense for today's task, fall back to (1) or (2).

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

        def perform(payload)
          session_id = payload[:session_id] || payload["session_id"]
          return unless session_id

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

          run_review(parent, system_prompt)
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

        def run_review(parent, system_prompt)
          child = fork_child(parent)
          runner = Agent::Runner.new(
            session_id: child[:id],
            model_override: parent[:model],
            # Inherit the parent's LIVE runtime provider (Hermes'
            # _current_main_runtime), i.e. the CONFIGURED provider the live
            # conversation actually runs on — the openai-compatible "gateway"
            # here — NOT the cosmetic model-name-inferred label the session row
            # stores (e.g. "deepseek"), which routes to a native provider with
            # no credentials configured and fails with "Missing <x>_api_key".
            # Using the config provider also guarantees the review hits the SAME
            # server slot as the live turn, which is the whole point of the
            # byte-identical prefix (shared warm KV cache).
            provider_override: Rubino.configuration.dig("model", "provider"),
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

          # Skill-only whitelist: memory has its OWN dedicated pipeline
          # (ExtractMemoryJob + session-end flush), so the review stays focused
          # on the skill library and can't double-write memory.
          Rubino.with_review_toolset(%w[skill]) do
            runner.run!(SKILL_REVIEW_PROMPT)
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
