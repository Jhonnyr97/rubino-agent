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
      # by UI::SubagentView#tool_started / #tool_finished (via
      # #record_tool_started / #record_tool_finished) under the registry mutex
      # and read by the parent renderer (UI::SubagentCards) and
      # the /agents drill-in. activity_log is a bounded ring of the last few
      # `✓ verb · hint` lines for the live drill-in; output_tail is the bounded
      # line buffer of the CURRENTLY RUNNING tool's streamed output (fed by
      # #record_tool_output, wiped at #record_tool_finished) that the drill-in's
      # output: block tails (#5). Nothing is persisted (it dies with the
      # process, like the rest of the registry).
      #
      # approval_gate / approval_question / approval_command are the
      # Option-2 approval-surfacing state: when a background child's tool needs
      # approval the child thread parks on `approval_gate` (a Run::ApprovalGate)
      # and the entry flips to status :needs_approval with the question/command
      # shown on the card; the user resolves it via /agents <id>.
      #
      # budget_request (#574) REUSES that exact :needs_approval gate for a
      # different ask: a BACKGROUND child that hit its tool-iteration ceiling
      # parks on the same gate to ask the human for MORE budget instead of
      # silently force-summarizing. The flag only re-flavors the surfaces (card /
      # menu row / the /agents resolve prompt read "wants +budget — grant?", and
      # the allowlist-persisting "always" option is dropped — there is no command
      # to remember); the parking/wake/stop-cancel plumbing is identical.
      Entry = Struct.new(
        :id, :subagent, :prompt, :status, :result, :error,
        :thread, :runner, :started_at, :finished_at,
        :last_activity, :tool_count, :activity_log, :output_tail,
        :approval_gate, :approval_id, :approval_question, :approval_command,
        :budget_request,
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
        # :ask_options — the OPTIONAL concrete answer choices the asking child
        # supplied (ask_parent `options:`). When present the human's answer
        # surface is an arrow-select of these options (+ a free-text "Answer"
        # entry); when nil it stays the [Answer / Dismiss] → free-text affordance.
        # Display/answer-shape only — never changes WHERE the answer is delivered.
        :ask_gate, :ask_id, :ask_question, :ask_blocking, :ask_options,
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
        # The SPAWNING side's input queue, captured on the PARENT thread at
        # spawn time (TaskTool#run_background) — the same spawn-captured sink
        # the [background-task] completion notice rides. ask_parent's
        # [subagent-question] notice for a top-level-owned child MUST use this:
        # reading the thread-local Rubino.background_sink on the CHILD's thread
        # resolves to the child's OWN steer_queue and misroutes the question
        # back into the asking child (#195). nil ⇒ no queue was wired
        # (sync/foreground spawn, headless).
        :parent_sink,
        keyword_init: true
      ) do
        # The child subagent's FULL persisted transcript. A background child runs
        # its own Agent::Runner with its own session, so its complete message
        # history (its tool calls + what it said) lives in the session store under
        # `runner.session[:id]` — the agent-attach view replays exactly this.
        # Empty when no runner/session is wired (sync/foreground/headless spawn).
        def messages
          session_id = runner&.session&.dig(:id)
          session_id ? ::Rubino::Session::Store.new.for_session(session_id) : []
        end
      end

      # How many recent activity lines the drill-in shows (the live `recent:` ring).
      ACTIVITY_LOG_MAX = 6

      # Bounds for the live output tail (#5): how many COMPLETE lines the
      # drill-in's output: block shows (the buffer keeps one extra slot for the
      # in-flight partial line), and the byte cap per buffered line so a
      # newline-free stream can't grow a line unbounded.
      OUTPUT_TAIL_MAX      = 6
      OUTPUT_TAIL_LINE_MAX = 200

      # Prefix #deliver_answer stamps on the steer-queue COPY of an answer it has
      # ALREADY delivered to the child via its ask gate (the dual-path delivery:
      # gate for a blocking ask, steer-queue for a non-blocking one). When the
      # child resumes via the gate and finishes WITHOUT another turn boundary, the
      # still-queued copy is drained by #complete and would surface as an
      # "undelivered steer note" — but the answer WAS delivered via the gate, so
      # reporting it undelivered is a false alarm (the /reply happy-path
      # regression from the H5 fix #457). The completion-notice paths filter notes
      # carrying this prefix OUT of the undelivered report for exactly that
      # reason; a genuine `/agents <id> steer "..."` note never carries it, so the
      # deliver-or-report-undelivered invariant for real steer notes is intact.
      ANSWER_NOTE_PREFIX = "[parent answer] "

      # The statuses under which a child still holds a concurrency slot: its
      # worker thread is alive — actively running, parked on a human approval,
      # parked on an escalated ask_parent (waiting on the human OR its
      # agent-parent), or unwinding after a stop request. This is the SINGLE
      # source of truth for "is this child still alive?", shared by the registry
      # itself (#running / #reserve cap) AND by every UI surface that lists live
      # children (the footer cards, the attached switcher, the navigable picker)
      # so they can never drift apart and silently drop a live-but-quiet child
      # from one surface while another still shows it (R1). Any new parked state
      # added to the lifecycle is made visible everywhere by editing this one set.
      LIVE_STATUSES = %i[running needs_approval blocked_on_human blocked_on_parent stopping].freeze

      class << self
        def instance
          @instance ||= new
        end

        # Test seam: drop all state between examples.
        def reset!
          @instance = nil
        end

        # The shared liveness oracle (see LIVE_STATUSES). Public so the UI
        # surfaces that format a registry snapshot (SubagentCards, AgentMenu)
        # filter by the EXACT same rule the registry uses, with no duplicated
        # status list to fall out of sync.
        def live_status?(status)
          LIVE_STATUSES.include?(status)
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
            id: new_id,
            subagent: subagent.to_s,
            prompt: prompt.to_s,
            status: :running,
            started_at: Time.now,
            tool_count: 0,
            activity_log: [],
            # Every background child gets its OWN steering queue at reserve time
            # so the parent can `/agents <id> steer "..."` it the instant it is
            # listed — no separate wiring step, no nil window.
            steer_queue: Interaction::InputQueue.new,
            owner_subagent_id: owner_subagent_id,
            depth: effective_depth
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

      # Marks a stop REQUEST (the /agents <id> --stop / task_stop path) on a
      # live entry so the list/cards immediately show ◌ stopping instead of a
      # stale ● running while the child unwinds at its next checkpoint (#108).
      # Returns true when the entry flipped. #complete then maps a failure on
      # a :stopping entry to the terminal :stopped, so a deliberate stop never
      # reads as ✗ failed (#13).
      def request_stop(id)
        @mutex.synchronize do
          entry = @entries[id]
          return false unless entry && live_status?(entry.status)

          entry.status = :stopping
          true
        end
      end

      # Records terminal state when the worker finishes (called from its
      # `ensure`). Single writer per entry, but guarded so #find/#list readers
      # see a consistent snapshot. A failure landing on a :stopping entry is a
      # USER-REQUESTED stop unwinding (Interrupted at the next checkpoint), so
      # it is recorded as :stopped — distinct from a genuine :failed (#108/#13).
      #
      # H5 — closes the drain↔complete race. The final drain of the child's
      # steer_queue happens HERE, under the SAME registry mutex that flips the
      # status to terminal, and #steer refuses to push onto a terminal entry
      # under that SAME mutex. So a steer/answer arriving concurrently is
      # serialised against this finalize: it is EITHER pushed before the status
      # flips (and drained right here into the returned `undelivered` notes) OR
      # rejected by #steer (which then honestly reports not-delivered). The
      # earlier shape — drain (InputQueue lock) then complete (registry lock),
      # two locks with a gap — let an answer land on a now-dead queue: dropped,
      # omitted from `undelivered`, yet reported delivered. Returns the notes
      # that were still queued at finalize time (never delivered to the child),
      # so the caller can surface them as undelivered.
      def complete(entry, status:, result: nil, error: nil)
        @mutex.synchronize do
          status            = :stopped if entry.status == :stopping && status == :failed
          entry.status      = status
          entry.result      = result
          entry.error       = error
          entry.finished_at = Time.now
          # Drain UNDER the mutex: anything still here is undelivered (the child
          # has no further turn to fold it in), and once status is terminal no
          # new note can arrive — #steer rejects it.
          entry.steer_queue&.drain || []
        end
      end

      # Records a child tool STARTING: bumps the tool counter and sets the
      # last-activity string the card/list show so concurrent tasks stay
      # distinguishable (#124/#127). Called from UI::SubagentView#tool_started,
      # which runs on the CHILD thread, so it MUST take the mutex (the parent
      # renderer reads these fields concurrently). No-op for an unknown id (a late event
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
      # read-heavy child. Also wipes the live output tail — it belongs to the
      # tool that just finished, so the drill-in's output: block clears (#5).
      def record_tool_finished(id, line)
        @mutex.synchronize do
          entry = @entries[id]
          return unless entry

          log = (entry.activity_log ||= [])
          log << line.to_s
          log.shift while log.size > ACTIVITY_LOG_MAX
          entry.output_tail = nil
        end
      end

      # Records a streamed chunk of the CURRENTLY RUNNING tool's output (#5):
      # splits on newlines into a bounded line buffer whose LAST slot carries
      # the in-flight partial line, so the /agents drill-in can tail it live.
      # Called from UI::SubagentView#tool_chunk on the CHILD thread, so it MUST
      # take the mutex like the other record_* writers. No-op for an unknown id.
      def record_tool_output(id, chunk)
        @mutex.synchronize do
          entry = @entries[id]
          return unless entry

          tail = (entry.output_tail ||= [""])
          chunk.to_s.each_line do |line|
            tail[-1] = "#{tail[-1]}#{line.chomp}"[0, OUTPUT_TAIL_LINE_MAX]
            tail << "" if line.end_with?("\n")
          end
          tail.shift while tail.size > OUTPUT_TAIL_MAX + 1
        end
      end

      # Flips an entry into the :needs_approval state and stores the gate +
      # question/command the card surfaces (Option 2). The child thread then
      # parks on `gate.await(approval_id)`; the user resolves it via
      # /agents <id>. Returns the previous status so the child can restore it.
      def begin_approval(id, gate:, approval_id:, question:, command:, budget: false)
        @mutex.synchronize do
          entry = @entries[id]
          return unless entry

          entry.approval_gate     = gate
          entry.approval_id       = approval_id
          entry.approval_question = question.to_s
          entry.approval_command  = command.to_s
          entry.budget_request    = budget ? true : false
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
          entry.budget_request    = false
          entry.status            = :running if entry.status == :needs_approval
        end
      end

      # Records a parent->child steer note (the `/agents <id> steer \"...\"`
      # affordance). Pushes the text onto the child's steering queue, which the
      # child Loop drains at its next iteration boundary (Loop#inject_steered_input)
      # — between turns, never between a tool_use and its results. Best-effort:
      # returns false (and pushes nothing) when the entry is gone, has no queue,
      # or has ALREADY reached a terminal state (the child finished — there is no
      # more turn to fold the note into); true when the note was queued.
      #
      # H5 — the push happens UNDER the registry mutex, gated on a non-terminal
      # status, so it is serialised against #complete (which flips the status to
      # terminal AND drains the queue under that SAME mutex). Either this push
      # wins the lock first (the note is queued and will be drained — by the
      # child at its next turn, or by #complete into the undelivered report) or
      # #complete wins first (status is terminal and this returns false). There
      # is no window in which a note is pushed onto a queue nobody will drain yet
      # reported delivered. Pushing inside the mutex is safe: InputQueue#push has
      # its own lock and never calls back into the registry, so no lock cycle.
      def steer(id, text)
        @mutex.synchronize do
          entry = @entries[id]
          return false unless entry&.steer_queue
          return false if terminal_status?(entry.status)

          entry.steer_queue.push(text)
          true
        end
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
      def begin_ask(id, gate:, ask_id:, question:, blocking:, owner_id: nil, options: nil) # rubocop:disable Metrics/ParameterLists -- keyword args recording one ask's state; splitting would obscure it
        @mutex.synchronize do
          entry = @entries[id]
          return unless entry

          entry.ask_gate     = gate
          entry.ask_id       = ask_id
          entry.ask_question = question.to_s
          entry.ask_blocking = blocking ? true : false
          # Normalize to a clean array of answer choices, or nil when none — so
          # the answer surface can branch on "options present?" without
          # re-validating. Each element is EITHER a plain string (label==value)
          # OR a {"label"=>, "description"=>} map (preserved as a hash, NOT
          # stringified into a Ruby literal — #475-3); a blank string / a map
          # without a usable label is dropped. A child that supplies no options
          # keeps the old (nil) shape.
          opts               = Array(options).filter_map { |o| normalize_ask_option(o) }
          entry.ask_options  = opts.empty? ? nil : opts
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
          entry.ask_options  = nil
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

        # H5 — #steer is the SINGLE race-free liveness oracle here: it pushes the
        # answer onto the steer_queue under the registry mutex IFF the child is
        # still non-terminal, returning false the instant the child has finished
        # (atomic against #complete, which flips the status and drains the queue
        # under that same mutex). So we steer FIRST and let its honest result
        # decide everything:
        #   false ⇒ the child already finished; neither path can reach it. Do NOT
        #           decide the gate (a no-op for a child that will never await
        #           it) and do NOT clear the ask — report not-delivered.
        #   true  ⇒ the child is live and the answer is queued; a BLOCKING ask
        #           additionally needs its gate decided so the parked child wakes
        #           with the answer as its tool result. Then clear the blocked
        #           state and report delivered.
        return false unless steer(entry.id, "#{ANSWER_NOTE_PREFIX}#{answer}")

        entry.ask_gate.decide(entry.ask_id, answer)
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

      # Stop-cascade (S5a): when a node is stopped, cancel the ask-gates of ALL
      # its descendants so a blocking ask anywhere in the subtree unwinds at once
      # (Run::ApprovalGate#cancel! wakes the parked child thread with Interrupted)
      # instead of leaving an orphaned grandchild parked until its bound elapses.
      # The descendant runners' CancelTokens are flipped by the caller's cancel!
      # of the node; this just makes the gate-parked ones wake immediately. Safe
      # to call on a node with no descendants or no blocked descendants.
      def cancel_descendant_ask_gates(id)
        descendants_of(id).each { |e| e.ask_gate&.cancel! }
      end

      # The ONE per-entry stop body, shared by every stop path (the human
      # /agents <id> --stop, the model-callable task_stop, and the
      # parent-teardown #cancel_all below). Marks the stop so the unwind records
      # as :stopped (not ✗ failed) and the list shows ◌ stopping, then wakes the
      # entry no matter HOW it is blocked: a child parked on its OWN approval or
      # ask gate (cancel those → Interrupted → clean unwind), any descendant
      # parked on a blocking ask (the stop-cascade), and the runner's CancelToken
      # for a child between checkpoints. Idempotent and safe on an already-stopped
      # or never-blocked entry (each cancel! is one-shot; request_stop no-ops on a
      # non-live status), so #cancel_all can call it across the whole registry.
      def stop_entry(entry)
        return unless entry

        request_stop(entry.id)
        entry.approval_gate&.cancel!
        entry.ask_gate&.cancel!
        cancel_descendant_ask_gates(entry.id)
        entry.runner&.cancel!
      end

      # Structured-concurrency teardown seam: cancel EVERY live subagent so the
      # process never leaves a child parked. The required fix for the parent-death
      # deadlock (#XXX) — when the PARENT dies/interrupts (REPL break, HUP/TERM,
      # clean quit, an aborted turn) a child blocked on ask_parent(blocking:true)
      # otherwise stays parked on its gate for the full ask_parent_timeout (~900s)
      # because nothing cancels its gate; the per-id stop paths only fire on an
      # explicit /agents --stop or task_stop. Calling this from each parent-death
      # edge wakes every blocked child SYNCHRONOUSLY (cancel! pushes its sentinel;
      # the gate's await observes it within one WAKE_TICK) so each unwinds via the
      # existing `rescue Rubino::Interrupted` with the clean "parent question was
      # cancelled" message instead of hanging to the bound. No-op when there are no
      # live children, and idempotent (#stop_entry is), so it is safe to invoke
      # from a teardown `ensure` and from a signal trap. Snapshots #running first
      # (outside the per-entry work) so we don't hold the registry mutex across the
      # gate/runner cancels.
      def cancel_all
        live = running
        live.each { |entry| stop_entry(entry) }
        # Logical cancel alone (above) only flips cancel tokens and trusts each
        # child THREAD to observe the token and reap its own shell within a wake
        # tick — but on parent-DEATH the process exits before the thread reaches
        # that checkpoint, so any shell a child spawned (its own pgid) reparents
        # to init as an orphan (MED-2). Reap the tracked shell process groups
        # SYNCHRONOUSLY here so the same parent-death edges that call cancel_all
        # (clean quit, HUP/TERM trap, REPL break) leave no surviving shell.
        ShellRegistry.instance.kill_all_groups
      end

      # Process-exit teardown: first do the cooperative cancel above, then give
      # child threads a short chance to finish and finally kill non-cooperative
      # survivors. Background subagents are Ruby threads, not OS child processes;
      # if a child is stuck in a provider read that never observes its cancel
      # token, a plain #cancel_all leaves the process alive waiting on that
      # non-daemon thread. This method is for chat shutdown only, not normal
      # per-task stops.
      def shutdown!(grace: 1.0)
        live = running
        cancel_all
        join_or_kill_threads(live, grace: grace)
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

      # Normalizes ONE supplied ask_parent answer choice (#475-3). Returns a clean
      # plain STRING for a plain string or a label-only map (label==value), a
      # {"label"=>, "description"=>} HASH for a {label, description} map (so the
      # picker can show the label + a dim description hint and still deliver the
      # label string — never a Ruby hash literal), or nil for a blank string / a
      # map without a usable label (dropped by the filter_map caller).
      def normalize_ask_option(opt)
        if opt.is_a?(Hash)
          label = (opt["label"] || opt[:label]).to_s.strip
          desc  = (opt["description"] || opt[:description]).to_s.strip
          return nil if label.empty?

          desc.empty? ? label : { "label" => label, "description" => desc }
        else
          s = opt.to_s.strip
          s.empty? ? nil : s
        end
      end

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

      # Instance-side shim onto the canonical class predicate (LIVE_STATUSES) so
      # the registry's own callers (#running, #reserve cap) and the UI surfaces
      # share ONE definition of "alive". See LIVE_STATUSES for the rationale.
      def live_status?(status)
        self.class.live_status?(status)
      end

      # A child has reached a TERMINAL state once #complete has run: its worker
      # thread is done, its steer_queue has been drained, and it has no further
      # turn to fold a steer note into. #steer rejects pushes onto a terminal
      # entry (H5) so an answer arriving after finalize is reported undelivered
      # rather than dropped-but-reported-delivered. :cancelled is included for
      # the API surface, which records cancellation via #complete too.
      def terminal_status?(status)
        %i[completed failed stopped cancelled].include?(status)
      end

      def running_count
        @entries.values.count { |e| live_status?(e.status) }
      end

      def new_id
        "sa_#{SecureRandom.hex(4)}"
      end

      def join_or_kill_threads(entries, grace:)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + [grace.to_f, 0.0].max
        entries.each do |entry|
          thread = entry.thread
          next unless joinable_thread?(thread)

          remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
          thread.join(remaining) if remaining.positive?

          thread = entry.thread
          next unless joinable_thread?(thread)

          thread.kill
          thread.join(0.2)
          force_stop(entry)
        end
      end

      def joinable_thread?(thread)
        thread && thread != Thread.current && thread.alive?
      end

      def force_stop(entry)
        @mutex.synchronize do
          return if terminal_status?(entry.status)

          entry.status = :stopped
          entry.error = "forced shutdown"
          entry.finished_at = Time.now
          entry.steer_queue&.drain
        end
      end
    end
  end
end
