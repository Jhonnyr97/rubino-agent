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
      # by a subagent's UI::CLI#tool_started / #tool_finished (via
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
        # How the child's turn TERMINATED (Agent::Loop#stop_reason). :completed on
        # a real answer; :max_time / :max_iterations / :stream_incomplete when the
        # run was force-summarized/truncated. Lets the completion notice, the card,
        # and task_result all report a truncated run as PARTIAL, not "completed".
        :stop_reason,
        :thread, :runner, :started_at, :finished_at,
        :last_activity, :tool_count, :activity_log, :output_tail,
        :approval_gate, :approval_id, :approval_question, :approval_command,
        :budget_request,
        # "Decide later" (#586): the user dismissed this request's AUTO-modal
        # without deciding it. The child stays parked on its gate and the
        # `wants +budget` card stays visible, but auto_resolve stops re-popping
        # the modal at idle — the user re-engages it deliberately via the picker /
        # `/agents <id>` (the manual path presents regardless). This is what makes
        # the picker's ↓+Enter gesture non-destructive: a stray gesture lands on
        # "Decide later" (defers) instead of "Summarize now". Cleared when the
        # approval is (re)opened or decided. nil/false ⇒ auto-pops normally.
        :approval_snoozed,
        # Monotonic stamp of the instant this child blocked on its approval gate
        # (begin_approval), used to order the approval MODAL QUEUE FIFO: only one
        # approval modal is presented at a time (awaiting_approval.first), and a
        # later-parked child waits its turn as part of the "(N more queued)"
        # backlog. Cleared on end_approval. nil ⇒ not currently parked.
        :approval_seq,
        # Parent->child steer (the `/agents <id> steer "..."` note). Wired into
        # the child Loop as its Interaction::InputQueue (the SAME turn-boundary
        # steering channel the human uses on the parent); the parent pushes a
        # note, the child folds it in at its next iteration via
        # Loop#inject_steered_input. nil ⇒ no steer wire (sync/foreground path).
        :steer_queue,
        # Ownership link (S1 — foundation for model-driven steer/probe).
        # owner_subagent_id is the `sa_*` id of the subagent that spawned this
        # child, or nil when the spawner is the human / top-level agent. depth is
        # 0 for a human-spawned child and owner.depth + 1 otherwise. The registry
        # stays a FLAT map keyed by id; the parent/child tree is computed over
        # owner_subagent_id.
        :owner_subagent_id, :depth,
        # Model-driven LIVE-probe budget (S3). probe_count is how many BILLED
        # `probe(live:true)` peeks the owner has run against this child.
        # Free snapshot probes (live:false) never touch this. Per-process, dies
        # with the registry like the rest of the live-progress state.
        :probe_count,
        # Path to the per-subagent JSONL log file (post-mortem forensics).
        # Survives process death so the user can inspect what happened.
        :log_path,
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

        # A subagent IS NOT a shell — the discriminator the shared /stop, steer,
        # probe and attach paths dispatch on (ShellEntryAdapter#shell? ⇒ true).
        def shell? = false

        # Parent→child steer: park a turn-boundary note on the child's queue
        # (folded in at its next iteration). The shell analogue is a stdin write.
        def steer(text)
          return false unless steer_queue

          steer_queue.push(text)
          true
        end

        # Ephemeral read-only peek: a synchronous LLM side-inference over the
        # child's current context. The shell analogue is an output snapshot.
        def peek(question)
          ::Rubino::Tools::SubagentProbe.new.peek(entry: self, question: question)
        end

        # A dim hint shown ABOVE a probe answer, or nil. A just-spawned subagent has
        # an empty context, so its honest "I'm not doing anything yet" reply would
        # read as broken (#112) without this; a shell has no such notion (its peek
        # IS its output), so the adapter returns nil.
        def peek_hint
          return unless tool_count.to_i.zero?

          "(snapshot at this instant — the child just started and its context is " \
            "still empty; probe again in a moment)"
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

      # Prefix the human's "deny & tell the agent why" reason carries when handed
      # to the child as a steer note (#Y1B). The note is ADVISORY — the approval
      # gate is already denied regardless — so when the child finishes before
      # folding it in, the still-queued copy drained by #complete must NOT raise
      # the scary "steer note not delivered (task completed first)" alarm: the
      # denial applied correctly and the explanation is moot. The completion paths
      # filter this prefix out of the undelivered WARNING (a calm note instead). A
      # genuine `/agents <id> steer` note never carries it, so its
      # deliver-or-report invariant is intact.
      DENY_NOTE_PREFIX = "[approval denied by human] "

      # The statuses under which a child still holds a concurrency slot: its
      # worker thread is alive — actively running, parked on a human approval, or
      # unwinding after a stop request. This is the SINGLE
      # source of truth for "is this child still alive?", shared by the registry
      # itself (#running / #reserve cap) AND by every UI surface that lists live
      # children (the footer cards, the attached switcher, the navigable picker)
      # so they can never drift apart and silently drop a live-but-quiet child
      # from one surface while another still shows it (R1). Any new parked state
      # added to the lifecycle is made visible everywhere by editing this one set.
      LIVE_STATUSES = %i[running needs_approval stopping].freeze

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
        # Monotonic source for approval_seq — the FIFO order of the approval
        # modal queue. Bumped under @mutex on every begin_approval so two
        # children that park "at once" still get a deterministic, stable order
        # (the one whose begin_approval won the lock first is the head).
        @approval_seq = 0
        # Inline tool adapters (live_card opt-in): registered by ToolExecutor
        # before a live_card tool runs, unregistered when it finishes. Read by
        # #running / #find / #list like subagents and shells, so the one
        # dropdown/cards/attach pipeline renders them with zero new branches.
        @inline_adapters = {}
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

      # Live cap values, from config when wired, else the built-in constants (so
      # a bare registry in a unit test with no Configuration still has sane
      # caps). PUBLIC so TaskTool#capacity_message can interpolate the SAME
      # resolved value #refusal_reason enforced against — the message can never
      # drift from what enforcement actually used.
      def max_depth
        config_int(:tasks_max_depth, MAX_DEPTH)
      end

      def max_children_per_node
        config_int(:tasks_max_children_per_node, MAX_CHILDREN_PER_NODE)
      end

      def max_concurrent_total
        config_int(:tasks_max_concurrent_total, MAX_CONCURRENT_TOTAL)
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
      def complete(entry, status:, result: nil, error: nil, stop_reason: nil)
        @mutex.synchronize do
          status            = :stopped if entry.status == :stopping && status == :failed
          entry.status      = status
          entry.result      = result
          entry.error       = error
          entry.stop_reason = stop_reason
          entry.finished_at = Time.now
          # Drain UNDER the mutex: anything still here is undelivered (the child
          # has no further turn to fold it in), and once status is terminal no
          # new note can arrive — #steer rejects it.
          entry.steer_queue&.drain || []
        end
      end

      # Records a child tool STARTING: bumps the tool counter and sets the
      # last-activity string the card/list show so concurrent tasks stay
      # distinguishable (#124/#127). Called from a subagent's UI::CLI#tool_started,
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
      # Called from a subagent's UI::CLI#tool_chunk on the CHILD thread, so it MUST
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
          entry.approval_snoozed  = false
          entry.approval_seq      = (@approval_seq += 1)
          entry.status            = :needs_approval
        end
      end

      # "Decide later" (#586): stop auto-popping THIS request's modal at idle
      # without deciding its gate — the child stays parked and the card stays
      # visible; the user re-engages via the picker / `/agents <id>`. Mirrors
      # begin/end_approval (one mutex-guarded mutation of the entry's approval
      # state); a no-op if the entry is gone.
      def snooze_approval(id)
        @mutex.synchronize do
          entry = @entries[id]
          return unless entry

          entry.approval_snoozed = true
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
          entry.approval_snoozed  = false
          entry.approval_seq      = nil
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
      # Send input to a background worker. The registry owns the liveness guard
      # (one place); the ACTION is polymorphic on the entry — a subagent parks a
      # turn-boundary steer note, a shell writes straight to its stdin.
      def steer(id, text)
        entry = find(id)
        return false unless entry
        return false if terminal_status?(entry.status)

        entry.steer(text)
      end

      # Records a BILLED live probe against a child (S3): bumps probe_count
      # under the mutex (the owner runs this on its own thread while the parent
      # renderer may read the entry). Returns the new count, or nil for an
      # unknown id. Free snapshot probes (live:false) never call this — only
      # `probe(live:true)` does, after the budget check passes.
      def record_live_probe(id)
        @mutex.synchronize do
          entry = @entries[id]
          return nil unless entry

          entry.probe_count = entry.probe_count.to_i + 1
          entry.probe_count
        end
      end

      # ── Inline tool adapters (live_card) ────────────────────────────

      # Max retained FINISHED inline adapters — prevents unbounded buffer
      # growth when many inline live_card tools run in a session. Finished
      # adapters stay retrievable (replay via drill-in) up to this cap;
      # the oldest finished ones are evicted when a new adapter is registered.
      MAX_RETAINED_INLINE = 64

      # Registers an InlineToolAdapter so it appears in the dropdown/cards
      # while a live_card tool runs. Called by ToolExecutor just before the
      # tool's #call. Evicts the oldest finished adapters if the retained
      # count exceeds MAX_RETAINED_INLINE (finished adapters are kept for
      # replay; #running already excludes them via live?).
      def register_inline(adapter)
        @mutex.synchronize do
          @inline_adapters[adapter.id] = adapter
          reap_retained_inlines!
        end
      end

      # Removes an inline adapter from the registry explicitly (e.g. session
      # end cleanup). Normal finish no longer calls this — finished adapters
      # are retained for replay and evicted by the bounded reap.
      def unregister_inline(id)
        @mutex.synchronize { @inline_adapters.delete(id) }
      end

      # Evicts the oldest finished (non-live) inline adapters when the total
      # exceeds MAX_RETAINED_INLINE. Called under @mutex from #register_inline.
      def reap_retained_inlines!
        finished = @inline_adapters.values.reject(&:live?)
                                   .sort_by(&:started_at)
        return unless finished.size > MAX_RETAINED_INLINE

        excess = finished.size - MAX_RETAINED_INLINE
        finished.first(excess).each { |a| @inline_adapters.delete(a.id) }
      end

      # Live inline adapters visible in the picker — only running tools whose
      # defer threshold (if any) has passed. Deferred adapters are buffering
      # silently and excluded until their deadline.
      def inline_adapters
        @mutex.synchronize { @inline_adapters.values.select { |a| a.live? && a.visible? } }
      end

      # Look up an inline adapter by id (for the attach path).
      def inline_adapter_for(id)
        @mutex.synchronize { @inline_adapters[id] }
      end

      # Entries currently parked on a human approval — surfaced on their card
      # and answerable via /agents <id>. Ordered OLDEST-FIRST (by the moment the
      # child blocked, approval_seq) so the modal queue is FIFO: when two
      # children raise an approval at once only ONE modal is presented at a time
      # (the head of this list — auto_resolve_pending takes #first), the rest are
      # the "(N more queued)" backlog shown on the active modal, and they dequeue
      # in the order they parked. Ties fall back to started_at for a stable order.
      def awaiting_approval
        @mutex.synchronize do
          @entries.values.select { |e| e.status == :needs_approval }
                         .sort_by { |e| [e.approval_seq.to_i, e.started_at] }
        end
      end

      # How many children are parked on an approval BEHIND the head — i.e. the
      # backlog the active modal advertises as "(N more queued)". Only ONE
      # approval modal is presented at a time (awaiting_approval.first); this is
      # everyone else still :needs_approval. Zero when at most one child is
      # parked. The active modal reads this so the user knows more are waiting
      # and that resolving the current one dequeues the next.
      def queued_approval_count
        [awaiting_approval.size - 1, 0].max
      end

      def find(id)
        @mutex.synchronize { @entries[id] } || shell_adapter_for(id) || inline_adapter_for(id)
      end

      # A read-time adapter for a background SHELL by id (bg_*), or nil. Lets the
      # shared /stop and attach paths resolve a shell exactly like a subagent
      # without the shell living in @entries (no cap/steer/sync coupling).
      def shell_adapter_for(id)
        shell = ShellRegistry.instance.find(id)
        shell ? ShellEntryAdapter.new(shell) : nil
      end

      # All entries, newest first — for a `task` listing (the /tasks analogue) and
      # the /agents list + /status count. Includes background shells (same unified
      # set as #running) so a running shell is never visible in the picker/cards
      # yet absent from the list/count.
      def list
        subs = @mutex.synchronize { @entries.values }
        # The list (/agents table, /status count) keeps FINISHED subagents, so it
        # keeps finished-but-retained shells too (running + retired) for symmetry —
        # otherwise a just-finished shell vanished from /agents while a finished
        # subagent lingered. #running stays running-only (the live picker/cards).
        shells = ShellRegistry.instance.listable_entries.map { |e| ShellEntryAdapter.new(e) }
        inlines = @mutex.synchronize { @inline_adapters.values }
        (subs + shells + inlines).sort_by(&:started_at).reverse
      end

      # Live (still-running) children — used by the parent stop path to cancel
      # orphans, and to enforce the concurrency cap. A child parked on a human
      # approval (:needs_approval) is STILL live (its thread is alive, holding a
      # slot), so it counts as running here.
      def running
        subs = @mutex.synchronize { @entries.values.select { |e| live_status?(e.status) } }
        subs + shell_adapters + inline_adapters
      end

      # Background SHELLS, presented as read-time adapters that duck-type a
      # subagent entry — the ONE place shells join the unified live set, so every
      # surface that lists "background work" (cards, picker, /agents list, /status
      # count) includes them with zero shell-specific branches. No second registry
      # entry ⇒ no status sync / double completion notice / concurrency-cap
      # pollution / dead steer_queue.
      def shell_adapters
        ShellRegistry.instance.running_entries.map { |e| ShellEntryAdapter.new(e) }
      end

      def remove(id)
        @mutex.synchronize { @entries.delete(id) }
      end

      # The ONE per-entry stop body, shared by every stop path (the human
      # /agents <id> --stop, the model-callable task_stop, and the
      # parent-teardown #cancel_all below). Marks the stop so the unwind records
      # as :stopped (not ✗ failed) and the list shows ◌ stopping, then wakes the
      # entry no matter HOW it is blocked: a child parked on its approval gate
      # (cancel it → Interrupted → clean unwind) and the runner's CancelToken for
      # a child between checkpoints. Idempotent and safe on an already-stopped or
      # never-blocked entry (each cancel! is one-shot; request_stop no-ops on a
      # non-live status), so #cancel_all can call it across the whole registry.
      def stop_entry(entry)
        return unless entry
        # A shell stops by killing its process group (polymorphic #stop on the
        # adapter), not by the cooperative subagent cancel.
        return entry.stop if entry.respond_to?(:shell?) && entry.shell?

        request_stop(entry.id)
        entry.approval_gate&.cancel!
        entry.runner&.cancel!
        # Cascade-kill the child background shells this subagent opened — stopping
        # a subagent stops its resources (Hermes kill_all(task_id)).
        ShellRegistry.instance.terminate_owned_by(entry.id)
      end

      # Structured-concurrency teardown seam: cancel EVERY live subagent so the
      # process never leaves a child parked. The required fix for the parent-death
      # deadlock (#XXX) — when the PARENT dies/interrupts (REPL break, HUP/TERM,
      # clean quit, an aborted turn) a child parked on its approval gate otherwise
      # stays parked for the full approval timeout because nothing cancels its
      # gate; the per-id stop paths only fire on an
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
      # steer/probe AUTHORIZATION checks build on).
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
      # rather than dropped-but-reported-delivered. The only producers are
      # #complete (:completed/:failed) and the stop path (:stopped); nothing sets
      # :cancelled, so it was inert defensive set membership and is dropped (#591).
      def terminal_status?(status)
        %i[completed failed stopped].include?(status)
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
