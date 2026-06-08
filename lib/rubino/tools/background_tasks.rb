# frozen_string_literal: true

require "securerandom"

module Rubino
  module Tools
    # Process-wide registry for subagents started by the `task` tool in the
    # BACKGROUND (the default). Mirrors ShellRegistry — the in-repo precedent
    # for "fire-and-forget + poll later + kill" — but the unit of work is a
    # nested Agent::Runner thread instead of a detached OS process.
    #
    # Each entry owns:
    #   - the worker Thread running the child Runner#run!,
    #   - the child Runner (so #cancel can flip its CancelToken — exactly the
    #     mechanism Run::Executor's stop-watcher uses for top-level runs),
    #   - the terminal status/result/error captured in the worker's `ensure`.
    #
    # The registry survives a single CLI/server process — like ShellRegistry it
    # is intentionally NOT persisted. Background subagents die with the process.
    #
    # Concurrency cap (mirrors the reference _DEFAULT_MAX_CONCURRENT_CHILDREN = 3): a
    # background subagent is a full LLM run = real cost, so #spawn refuses past
    # MAX_CONCURRENT live children rather than fanning out unbounded threads.
    class BackgroundTasks
      MAX_CONCURRENT = 3

      # last_activity / tool_count / activity_log — live-progress fields written
      # by the child's EventBus tap (TaskTool#wire_child_activity) under the
      # registry mutex and read by the parent renderer (UI::SubagentCards) and
      # the /agents drill-in. activity_log is a bounded ring of the last few
      # `✓ verb · hint` lines for the live drill-in; nothing is persisted (it
      # dies with the process, like the rest of the registry).
      #
      # approval_gate / approval_question / approval_command are the
      # Option-2 approval-surfacing state: when a background child's tool needs
      # approval the child thread parks on `approval_gate` (a Run::ApprovalGate)
      # and the entry flips to status :needs_approval with the question/command
      # shown on the card; the user resolves it via /agents <id>.
      Entry = Struct.new(
        :id, :subagent, :prompt, :status, :result, :error,
        :thread, :runner, :started_at, :finished_at,
        :last_activity, :tool_count, :activity_log,
        :approval_gate, :approval_id, :approval_question, :approval_command,
        # Parent->child steer (the `/agents <id> steer "..."` note). Wired into
        # the child Loop as its Interaction::InputQueue (the SAME turn-boundary
        # steering channel the human uses on the parent); the parent pushes a
        # note, the child folds it in at its next iteration via
        # Loop#inject_steered_input. nil ⇒ no steer wire (sync/foreground path).
        :steer_queue,
        # child->parent ask_parent escalation (Run::ApprovalGate handoff). When a
        # subagent calls ask_parent and it escalates to the HUMAN, the child
        # parks on `ask_gate` keyed by `ask_id`, the entry flips to
        # :blocked_on_human, and the card/banner surface `ask_question`. A
        # blocking ask holds the child's worker thread on the gate (bounded only
        # by an explicit /reply or stop — see ask_parent_tool.rb); a non-blocking
        # ask returns immediately and the answer is delivered later via
        # `steer_queue`. The human answers via /reply <id>, which decides the gate.
        :ask_gate, :ask_id, :ask_question, :ask_blocking,
        keyword_init: true
      )

      # How many recent activity lines the drill-in shows (the live `recent:` ring).
      ACTIVITY_LOG_MAX = 6

      class << self
        def instance
          @instance ||= new
        end

        # Test seam: drop all state between examples.
        def reset!
          @instance = nil
        end
      end

      def initialize
        @entries = {}
        @mutex   = Mutex.new
      end

      # Reserves a slot and registers a `running` entry, returning it. The
      # caller then attaches the worker thread + runner via #attach. Returns nil
      # when the registry is at capacity so the tool can surface an at-capacity
      # message instead of spawning unbounded work.
      def reserve(subagent:, prompt:)
        @mutex.synchronize do
          return nil if running_count >= MAX_CONCURRENT

          entry = Entry.new(
            id:           new_id,
            subagent:     subagent.to_s,
            prompt:       prompt.to_s,
            status:       :running,
            started_at:   Time.now,
            tool_count:   0,
            activity_log: [],
            # Every background child gets its OWN steering queue at reserve time
            # so the parent can `/agents <id> steer "..."` it the instant it is
            # listed — no separate wiring step, no nil window.
            steer_queue:  Interaction::InputQueue.new
          )
          @entries[entry.id] = entry
          entry
        end
      end

      # Binds the live worker thread + child runner to a reserved entry so the
      # registry can later cancel it. Done after reserve so the entry exists in
      # the map before the thread starts (no race on completion writing back).
      def attach(entry, thread:, runner:)
        @mutex.synchronize do
          entry.thread = thread
          entry.runner = runner
        end
      end

      # Records terminal state when the worker finishes (called from its
      # `ensure`). Single writer per entry, but guarded so #find/#list readers
      # see a consistent snapshot.
      def complete(entry, status:, result: nil, error: nil)
        @mutex.synchronize do
          entry.status      = status
          entry.result      = result
          entry.error       = error
          entry.finished_at = Time.now
        end
      end

      # Records a child tool STARTING: bumps the tool counter and sets the
      # last-activity string the card/list show so concurrent tasks stay
      # distinguishable (#124/#127). Called from the child's EventBus tap, which
      # runs on the CHILD thread, so it MUST take the mutex (the parent renderer
      # reads these fields concurrently). No-op for an unknown id (a late event
      # after #remove).
      def record_tool_started(id, activity)
        @mutex.synchronize do
          entry = @entries[id]
          return unless entry

          entry.tool_count = entry.tool_count.to_i + 1
          entry.last_activity = activity.to_s
        end
      end

      # Records a child tool FINISHING: appends a terse line to the bounded
      # activity ring the live drill-in (#71) tails. Keeps the last
      # ACTIVITY_LOG_MAX entries so the ring never grows unbounded for a
      # read-heavy child.
      def record_tool_finished(id, line)
        @mutex.synchronize do
          entry = @entries[id]
          return unless entry

          log = (entry.activity_log ||= [])
          log << line.to_s
          log.shift while log.size > ACTIVITY_LOG_MAX
        end
      end

      # Flips an entry into the :needs_approval state and stores the gate +
      # question/command the card surfaces (Option 2). The child thread then
      # parks on `gate.await(approval_id)`; the user resolves it via
      # /agents <id>. Returns the previous status so the child can restore it.
      def begin_approval(id, gate:, approval_id:, question:, command:)
        @mutex.synchronize do
          entry = @entries[id]
          return unless entry

          entry.approval_gate     = gate
          entry.approval_id       = approval_id
          entry.approval_question = question.to_s
          entry.approval_command  = command.to_s
          entry.status            = :needs_approval
        end
      end

      # Clears the approval state and returns the entry to :running once a
      # decision has been delivered (or the child unwinds).
      def end_approval(id)
        @mutex.synchronize do
          entry = @entries[id]
          return unless entry

          entry.approval_gate     = nil
          entry.approval_id       = nil
          entry.approval_question = nil
          entry.approval_command  = nil
          entry.status            = :running if entry.status == :needs_approval
        end
      end

      # Records a parent->child steer note (the `/agents <id> steer \"...\"`
      # affordance). Pushes the text onto the child's steering queue, which the
      # child Loop drains at its next iteration boundary (Loop#inject_steered_input)
      # — between turns, never between a tool_use and its results. Best-effort:
      # returns false (and pushes nothing) when the entry is gone or has no queue
      # (e.g. a finished child), true when the note was queued.
      def steer(id, text)
        queue = @mutex.synchronize do
          entry = @entries[id]
          entry&.steer_queue
        end
        return false unless queue

        queue.push(text)
        true
      end

      # Flips an entry into the :blocked_on_human state for an escalated
      # ask_parent: stores the gate + question + blocking flag the card/banner
      # surface (mirror of #begin_approval, but for a child->parent question that
      # the parent couldn't answer and escalated to the human). The child thread
      # then parks on `ask_gate.await(ask_id)` (blocking ask) until /reply <id>
      # decides the gate, or keeps working (non-blocking ask) with the answer
      # delivered later via the steer queue. A child in this state still holds a
      # concurrency slot (its thread is alive, or it is awaiting the human), so it
      # counts as live.
      def begin_ask(id, gate:, ask_id:, question:, blocking:)
        @mutex.synchronize do
          entry = @entries[id]
          return unless entry

          entry.ask_gate     = gate
          entry.ask_id       = ask_id
          entry.ask_question = question.to_s
          entry.ask_blocking = blocking ? true : false
          entry.status       = :blocked_on_human
        end
      end

      # Clears the ask state and returns the entry to :running once the human has
      # answered (or the child unwinds / is stopped).
      def end_ask(id)
        @mutex.synchronize do
          entry = @entries[id]
          return unless entry

          entry.ask_gate     = nil
          entry.ask_id       = nil
          entry.ask_question = nil
          entry.ask_blocking = nil
          entry.status       = :running if entry.status == :blocked_on_human
        end
      end

      # Entries parked on an escalated ask_parent, waiting on THE HUMAN — the
      # source of the persistent \"\u26d4 N subagent waiting on you\" marker and
      # answerable via /reply <id>.
      def awaiting_human
        @mutex.synchronize { @entries.values.select { |e| e.status == :blocked_on_human } }
      end

      # Entries currently parked on a human approval — surfaced on their card
      # and answerable via /agents <id>.
      def awaiting_approval
        @mutex.synchronize { @entries.values.select { |e| e.status == :needs_approval } }
      end

      def find(id)
        @mutex.synchronize { @entries[id] }
      end

      # All entries, newest first — for a `task` listing (the /tasks analogue).
      def list
        @mutex.synchronize { @entries.values.sort_by(&:started_at).reverse }
      end

      # Live (still-running) children — used by the parent stop path to cancel
      # orphans, and to enforce the concurrency cap. A child parked on a human
      # approval (:needs_approval) is STILL live (its thread is alive, holding a
      # slot), so it counts as running here.
      def running
        @mutex.synchronize { @entries.values.select { |e| live_status?(e.status) } }
      end

      def remove(id)
        @mutex.synchronize { @entries.delete(id) }
      end

      private

      # A child holds a concurrency slot while its thread is alive — whether
      # actively running, parked on a human approval, or parked on an escalated
      # ask_parent question waiting on the human.
      def live_status?(status)
        status == :running || status == :needs_approval || status == :blocked_on_human
      end

      def running_count
        @entries.values.count { |e| live_status?(e.status) }
      end

      def new_id
        "sa_#{SecureRandom.hex(4)}"
      end
    end
  end
end
