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

      # Fallback caps for the nested-subagent tree, used when config is absent
      # (e.g. a bare registry in a unit test with no Configuration wired). The
      # live values come from config (tasks.max_depth / max_children_per_node /
      # max_concurrent_total); these constants are the built-in defaults the
      # config keys themselves default to. All three are enforced in #reserve.
      MAX_DEPTH             = 2
      MAX_CHILDREN_PER_NODE = 3
      MAX_CONCURRENT_TOTAL  = 8

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
        # Ownership link (S1 — foundation for model-driven steer/probe/ask_parent).
        # owner_subagent_id is the `sa_*` id of the subagent that spawned this
        # child, or nil when the spawner is the human / top-level agent. depth is
        # 0 for a human-spawned child and owner.depth + 1 otherwise. The registry
        # stays a FLAT map keyed by id; the parent/child tree is computed over
        # owner_subagent_id (see #children_of / #descendants_of / #ancestors_of).
        :owner_subagent_id, :depth,
        # Model-driven LIVE-probe budget (S3). probe_count is how many BILLED
        # `probe(live:true)` peeks the owner has run against this child;
        # last_probe_at is when the last one ran (for an optional min-interval).
        # Free snapshot probes (live:false) never touch these. Per-process, dies
        # with the registry like the rest of the live-progress state.
        :probe_count, :last_probe_at,
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
      # caller then attaches the worker thread + runner via #attach.
      #
      # owner_subagent_id is the `sa_*` id of the SPAWNING subagent (nil ⇒ the
      # human / top-level agent spawned this child). depth is the caller's hint
      # for a human-spawned child (0); for an owner-spawned child the depth is
      # recomputed here from the owner entry (owner.depth + 1) so a stale hint
      # can't smuggle a child past the depth cap.
      #
      # Returns nil — so TaskTool can surface a clear message instead of spawning
      # unbounded work — when ANY of the three nesting caps is hit. The reason is
      # available via #last_refusal_reason for the caller to phrase the message:
      #   :depth          — depth >= max_depth (no deeper nesting allowed)
      #   :per_owner      — this owner already has max_children_per_node live kids
      #   :global         — total live subagents across the tree >= max total
      # This is the SINGLE enforcement point for every nesting limit.
      def reserve(subagent:, prompt:, owner_subagent_id: nil, depth: 0)
        @mutex.synchronize do
          owner = owner_subagent_id ? @entries[owner_subagent_id] : nil
          effective_depth = owner ? owner.depth.to_i + 1 : depth.to_i

          @last_refusal_reason = refusal_reason(owner_subagent_id, effective_depth)
          return nil if @last_refusal_reason

          entry = Entry.new(
            id:                new_id,
            subagent:          subagent.to_s,
            prompt:            prompt.to_s,
            status:            :running,
            started_at:        Time.now,
            tool_count:        0,
            activity_log:      [],
            # Every background child gets its OWN steering queue at reserve time
            # so the parent can `/agents <id> steer "..."` it the instant it is
            # listed — no separate wiring step, no nil window.
            steer_queue:       Interaction::InputQueue.new,
            owner_subagent_id: owner_subagent_id,
            depth:             effective_depth
          )
          @entries[entry.id] = entry
          entry
        end
      end

      # Why the most recent #reserve returned nil (one of :depth / :per_owner /
      # :global), or nil when the last reserve succeeded. Read by TaskTool to
      # phrase a reason-specific at-capacity message.
      attr_reader :last_refusal_reason

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

      # Records a BILLED live probe against a child (S3): bumps probe_count and
      # stamps last_probe_at, under the mutex (the owner runs this on its own
      # thread while the parent renderer may read the entry). Returns the new
      # count, or nil for an unknown id. Free snapshot probes (live:false) never
      # call this — only `probe(live:true)` does, after the budget check passes.
      def record_live_probe(id)
        @mutex.synchronize do
          entry = @entries[id]
          return nil unless entry

          entry.probe_count   = entry.probe_count.to_i + 1
          entry.last_probe_at = Time.now
          entry.probe_count
        end
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
      # The status depends on WHO owns the asking child (S4): owner_id present (an
      # agent-parent) → :blocked_on_parent (the parent MODEL answers via
      # answer_child; the question was pushed onto the owner's steer_queue, NOT
      # the human's job); owner_id nil (the human / top-level) → :blocked_on_human
      # (the human answers via /reply <id>).
      def begin_ask(id, gate:, ask_id:, question:, blocking:, owner_id: nil)
        @mutex.synchronize do
          entry = @entries[id]
          return unless entry

          entry.ask_gate     = gate
          entry.ask_id       = ask_id
          entry.ask_question = question.to_s
          entry.ask_blocking = blocking ? true : false
          entry.status       = owner_id ? :blocked_on_parent : :blocked_on_human
        end
      end

      # Clears the ask state and returns the entry to :running once the question
      # has been answered (by the human via /reply, or the agent-parent via
      # answer_child), or the child unwinds / is stopped.
      def end_ask(id)
        @mutex.synchronize do
          entry = @entries[id]
          return unless entry

          entry.ask_gate     = nil
          entry.ask_id       = nil
          entry.ask_question = nil
          entry.ask_blocking = nil
          entry.status       = :running if %i[blocked_on_human blocked_on_parent].include?(entry.status)
        end
      end

      # The ONE shared answer wire for an escalated ask_parent, used by BOTH the
      # human /reply path (Commands::Executor#deliver_reply) and the model-callable
      # `answer_child` tool: route the answer back DOWN to the asking child by
      # (1) deciding its ask gate — unblocks a BLOCKING ask with the answer as its
      # tool result — and (2) pushing the answer onto its steer queue so a
      # NON-BLOCKING ask folds it in at its next turn boundary; then clear the
      # blocked state (#end_ask). Either way the answer PERSISTS in the child's
      # context. No-op (returns false) for an unknown id or one not awaiting an
      # answer (no ask_gate); true when the answer was routed.
      def deliver_answer(id, answer)
        entry = find(id)
        return false unless entry&.ask_gate

        entry.ask_gate.decide(entry.ask_id, answer)
        steer(entry.id, "[parent answer] #{answer}")
        end_ask(entry.id)
        true
      end

      # Entries parked on an escalated ask_parent, waiting on THE HUMAN — the
      # source of the persistent \"\u26d4 N subagent waiting on you\" marker and
      # answerable via /reply <id>. Counts ONLY :blocked_on_human: a
      # :blocked_on_parent child is its agent-parent's job (answer_child), not the
      # human's, so it must NOT inflate the human's "waiting on you" count.
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

      # --- Tree over owner_subagent_id (the registry stays a flat map) ---------

      # Direct children of `id`: entries whose owner_subagent_id == id. Pass nil
      # for the human/top-level node's direct children.
      def children_of(id)
        @mutex.synchronize { @entries.values.select { |e| e.owner_subagent_id == id } }
      end

      # All transitive descendants of `id` (BFS over owner_subagent_id), in
      # breadth order. Cycle-safe (an id is visited at most once).
      def descendants_of(id)
        @mutex.synchronize do
          out     = []
          seen    = {}
          frontier = @entries.values.select { |e| e.owner_subagent_id == id }
          until frontier.empty?
            nxt = []
            frontier.each do |e|
              next if seen[e.id]

              seen[e.id] = true
              out << e
              nxt.concat(@entries.values.select { |c| c.owner_subagent_id == e.id })
            end
            frontier = nxt
          end
          out
        end
      end

      # The chain of ancestors of `id`, nearest parent first, walking
      # owner_subagent_id up to the human/top-level root. Cycle-safe.
      def ancestors_of(id)
        @mutex.synchronize do
          out  = []
          seen = { id => true }
          cur  = @entries[id]&.owner_subagent_id
          while cur && (entry = @entries[cur]) && !seen[cur]
            seen[cur] = true
            out << entry
            cur = entry.owner_subagent_id
          end
          out
        end
      end

      # True iff `child_id`'s direct owner is `parent_id` (the ownership predicate
      # later slices' steer/probe/answer_child AUTHORIZATION checks will build on).
      def owned_by?(parent_id, child_id)
        @mutex.synchronize do
          child = @entries[child_id]
          !child.nil? && child.owner_subagent_id == parent_id
        end
      end

      private

      # The reason (if any) a reserve at this owner/depth must be refused, checked
      # in the documented order. nil ⇒ allowed. Runs UNDER the mutex (callers hold
      # it), reading the live entry map for the per-owner and global live counts.
      def refusal_reason(owner_subagent_id, effective_depth)
        return :depth if effective_depth >= max_depth
        return :global if running_count >= max_concurrent_total

        live_children = @entries.values.count do |e|
          e.owner_subagent_id == owner_subagent_id && live_status?(e.status)
        end
        return :per_owner if live_children >= max_children_per_node

        nil
      end

      # Live cap values, from config when wired, else the built-in constants (so a
      # bare registry in a unit test with no Configuration still has sane caps).
      def max_depth
        config_int(:tasks_max_depth, MAX_DEPTH)
      end

      def max_children_per_node
        config_int(:tasks_max_children_per_node, MAX_CHILDREN_PER_NODE)
      end

      def max_concurrent_total
        config_int(:tasks_max_concurrent_total, MAX_CONCURRENT_TOTAL)
      end

      def config_int(accessor, fallback)
        cfg = Rubino.configuration if Rubino.respond_to?(:configuration)
        val = cfg&.respond_to?(accessor) ? cfg.public_send(accessor) : nil
        Integer(val)
      rescue StandardError, TypeError, ArgumentError
        fallback
      end

      # A child holds a concurrency slot while its thread is alive — whether
      # actively running, parked on a human approval, or parked on an escalated
      # ask_parent question (waiting on the human OR on its agent-parent). Both
      # blocked states hold a live thread, so both count as live.
      def live_status?(status)
        %i[running needs_approval blocked_on_human blocked_on_parent].include?(status)
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
