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
            activity_log: []
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
      # actively running or parked on a human approval.
      def live_status?(status)
        status == :running || status == :needs_approval
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
