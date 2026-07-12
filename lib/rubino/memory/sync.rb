# frozen_string_literal: true

module Rubino
  module Memory
    # Hermes-style inline post-turn memory extraction.
    #
    # Called from Lifecycle#execute after every COMPLETED turn. Runs the
    # heavy LLM extraction on a single daemon thread so the loop is never
    # blocked — the call returns immediately (fire-and-forget).
    #
    # Mirrors hermes-agent's memory_manager.sync_all called synchronously in
    # run_agent.py right after the assistant's full turn response is persisted,
    # before the next input. The LOOP call is inline; the LLM work is off the
    # hot path on an in-process daemon thread.
    #
    # Coalesces: at most one extraction runs at a time. A new turn fires a
    # sync; if the previous one is still running it is skipped — the next
    # turn will attempt again (best-effort, nothing lost).
    class Sync
      @mutex = Mutex.new
      @thread = nil

      class << self
        # Called inline from Lifecycle#execute after the turn completes and
        # post-turn jobs are enqueued. Fire-and-forget: returns immediately.
        #
        # Gated on:
        #   - memory.auto_extract config enabled
        #   - stop_reason == :completed (skip on aborted/interrupted turns)
        #   - the interval throttle (memory.auto_extract_interval)
        #
        # On failure: logs and continues — never crashes the loop.
        def sync_after_turn(session_id, stop_reason:, config: Rubino.configuration)
          config ||= Rubino.configuration
          return unless config.respond_to?(:memory_auto_extract?) && config.memory_auto_extract?
          return unless stop_reason == :completed
          return unless interval_due?(session_id, config)

          @mutex.synchronize do
            return if @thread&.alive?

            @thread = Thread.new do
              run_extraction(session_id, config)
            rescue StandardError => e
              Rubino.logger.warn(
                event: "memory.sync.failed",
                session_id: session_id,
                error_class: e.class.name,
                message: e.message
              )
            end
            @thread.abort_on_exception = false
          end
        end

        # True while the daemon extraction thread is alive.
        def running?
          @mutex.synchronize { @thread&.alive? || false }
        end

        private

        # Runs the memory extraction: forks a child session, runs a review
        # turn with only the memory tool, and cleans up. Reuses the existing
        # BackgroundReviewJob extraction logic (same MEMORY_REVIEW_PROMPT,
        # same fork+run mechanic).
        def run_extraction(session_id, config)
          parent = Session::Repository.new.find(session_id)
          return unless parent

          store = Session::Store.new
          messages = store.for_session(session_id)
          return unless succeeded?(messages)

          system_prompt = Context::PromptAssembler.system_prompt_for(session_id)
          return unless system_prompt

          # Fork a disposable child session seeded with the parent's full
          # conversation snapshot (mirrors BackgroundReviewJob#fork_child).
          repo = Session::Repository.new
          child = repo.create(
            source: "review",
            model: parent[:model],
            provider: parent[:provider],
            title: parent[:title],
            parent_session_id: parent[:id],
            cwd: parent[:cwd]
          )
          store.copy_into(child[:id], messages)
          repo.update(child[:id], message_count: store.count(child[:id]))

          run_review_turn(parent: parent, child: child, system_prompt: system_prompt,
                          session_id: session_id, config: config)
        ensure
          begin
            repo&.destroy!(child[:id]) if child
          rescue StandardError => e
            Rubino.logger.warn(
              event: "memory.sync.cleanup_failed",
              error_class: e.class.name,
              message: e.message
            )
          end
        end

        def succeeded?(messages)
          messages.any? do |m|
            m.respond_to?(:role) &&
              m.role == "assistant" &&
              !m.content.to_s.strip.empty?
          end
        end

        # Run the review turn. The memory tool is pre-approved (trusted
        # sandboxed write to the memory store); no human to answer an
        # approval gate on this daemon thread. source_session_id is bound
        # so every fact written is attributed to the triggering session.
        def run_review_turn(parent:, child:, system_prompt:, session_id:, config:)
          Rubino.with_review_toolset(["memory"]) do
            Rubino.with_memory_source_session_id(session_id) do
              runner = Agent::Runner.new(
                session_id: child[:id],
                model_override: parent[:model],
                provider_override: config.dig("model", "provider"),
                ui: UI::Null.new,
                interactive: false,
                announce_session: false,
                session_source: "review",
                system_prompt_override: system_prompt,
                event_bus: Rubino.event_bus
              )
              runner.run!(MEMORY_REVIEW_PROMPT)
            end
          end
        end

        # True when the per-session turn counter lands on the
        # memory.auto_extract_interval boundary. Every turn for interval <= 1,
        # else on turns that land on the interval.
        def interval_due?(session_id, config)
          interval = config.memory_auto_extract_interval
          return true if interval.nil? || interval <= 1

          repo = Session::Repository.new
          row = repo.find(session_id)
          count = row && (row[:message_count] || row["message_count"])
          turn_no = count ? [count.to_i / 2, 1].max : 1
          (turn_no % interval).zero?
        rescue StandardError
          true
        end
      end

      # The memory half of the review (from BackgroundReviewJob): the agent
      # decides agentically which durable facts from the conversation are worth
      # persisting, using the `memory` tool. Same warm-prefix fork, same
      # restricted toolset. Inlined here to avoid a load-order dependency on
      # Jobs::Handlers::BackgroundReviewJob.
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
    end
  end
end
