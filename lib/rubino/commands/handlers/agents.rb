# frozen_string_literal: true

require "pastel"
require "time"

module Rubino
  module Commands
    module Handlers
      # The `/agents` (alias `/tasks`) drill-in surface and the `/reply` answer
      # path, extracted from Commands::Executor (batch B).
      #
      # The "see what other agents do" surface. Lists background subagents from
      # the BackgroundTasks registry (the async `task` substrate), drills into a
      # single one's result/error, steers/probes/stops a running one, and routes
      # a human /reply back down to a blocked child.
      #
      #   /agents                 → list
      #   /agents <id>            → drill-in (result / error / status)
      #   /agents <id> --stop     → cancel a running subagent
      #   /agents <id> steer "…"  → fire-and-forget note into the child's context
      #   /agents <id> probe "…"  → ephemeral read-only peek
      #   /reply <id> <answer>    → answer a child blocked on a human/parent ask
      class Agents
        include Rubino::UI::ProbeWaitIndicator

        # How many times the parked-child approval prompt re-renders after an
        # empty/aborted read (#144) before giving up and leaving the child parked.
        APPROVAL_ASK_ATTEMPTS = 3

        # Appended to every "no such subagent id" error (item 5). Subagent ids
        # (sa_*) live ONLY in the current process — the BackgroundTasks registry
        # is in-memory, never persisted — so a prior session's id is genuinely
        # gone after a REPL restart. The bare "no such id" left the user thinking
        # they'd mistyped; this names the real reason so they don't hunt for a
        # typo. Surfaced from EVERY not-found path (/agents <id>, /reply <id>,
        # /stop <id>, steer, probe).
        RESET_HINT = "(subagents reset when rubino restarts)"

        def initialize(ui:)
          @ui = ui
        end

        # Auto-open the EXISTING interactive prompt for ONE pending subagent
        # request the human must act on — the REPL idle loop calls this at every
        # idle tick so the affordance presents ITSELF instead of forcing the user
        # to guess `/agents <id>` or `/reply <id>` (the maintainer's "auto-open
        # the existing dropdown" ask). A request that arrives mid-turn, or
        # survives a turn that is interrupted/aborted, is re-detected here the
        # next time the REPL returns to idle, so it is never lost.
        #
        # Reuses the SAME primitives the manual slash paths use:
        #   :needs_approval   → #resolve_agent_approval  (the approve/deny/always
        #                       prompt, identical to /agents <id>)
        #   :blocked_on_human → #prompt_reply_answer + #deliver_reply (the ◆ ask
        #                       takeover, identical to /reply <id> with no inline
        #                       answer)
        # The manual slash commands stay as a fallback; this is just the primary,
        # zero-typing surface. Approval is offered FIRST (a parked tool holds a
        # concurrency slot and a possibly dangerous side effect, so it is the more
        # urgent gate). Resolves at most ONE request per call so the loop repaints
        # and re-checks between each. Returns true when it presented a request
        # (the caller re-polls), false when nothing was pending.
        #
        # SECURITY: this changes WHEN the existing approval prompt appears (now it
        # auto-presents), never WHAT requires approval — the gate semantics, the
        # policy that flips a child to :needs_approval, and the approve/deny/always
        # persistence are untouched. The human still makes the same explicit
        # decision through the same gate.
        def auto_resolve_pending # rubocop:disable Naming/PredicateMethod -- a prompt-presenting mutator that reports whether it surfaced a request, not a pure query
          registry = Tools::BackgroundTasks.instance
          if (entry = registry.awaiting_approval.first)
            resolve_agent_approval(entry)
            return true
          end
          if (entry = registry.awaiting_human.first)
            answer_one_human(entry)
            return true
          end
          false
        end

        # The ONE shared "surface the answer affordance for a child blocked on the
        # human, read the human's answer, deliver it down the SAME wire" step —
        # used by BOTH the idle poll (#auto_resolve_pending) and the mid-turn
        # auto-open (BottomComposer#request_takeover, triggered by the child's
        # ask_parent the instant it blocks). Keeping it in one method means the
        # delivery semantics (free-text or pick-an-option → #deliver_reply →
        # BackgroundTasks#deliver_answer) are identical on both paths and the
        # parent turn's state is NEVER touched (deliver_answer only decides the
        # child's gate + pushes its steer note under the registry mutex).
        #
        # An empty answer (the human cancelled — Esc in the dropdown / blank
        # free-text) leaves the child PARKED and reports it: the affordance/hint
        # stays so it can re-open. Returns true once it surfaced the request
        # (the caller re-polls / re-reads awaiting_human for the next head).
        def answer_one_human(entry) # rubocop:disable Naming/PredicateMethod -- a prompt-presenting mutator that reports it surfaced a request
          answer = prompt_reply_answer(entry)
          if answer.to_s.strip.empty?
            @ui.info("No answer given — #{entry.id} is still waiting.")
          else
            deliver_reply(entry, answer)
          end
          true
        end

        # FIFO drain of the children blocked on the human, used by the MID-TURN
        # auto-open: deliver the head, then RE-READ awaiting_human (a 2nd child
        # may have asked while the dropdown was open, or the head may have been
        # delivered/timed-out) and surface the next head, until the queue is
        # empty. Each #answer_one_human runs its own dropdown takeover; a child
        # that arrives mid-open simply appends and is picked up on the re-read.
        # Bounded by the live awaiting_human snapshot shrinking each pass, so it
        # always terminates. Runs on the INPUT thread (it owns the keyboard).
        def answer_all_human
          loop do
            entry = Tools::BackgroundTasks.instance.awaiting_human.first
            break unless entry

            answer_one_human(entry)
            # A cancelled (still-blocked) head would otherwise re-surface forever:
            # stop once the head is no longer awaiting an answer it just got, OR
            # the human declined it. We break when the FIRST awaiting_human entry
            # is unchanged after the attempt (cancelled), so an Esc doesn't loop.
            still = Tools::BackgroundTasks.instance.awaiting_human.first
            break if still && still.id == entry.id
          end
        end

        def handle_agents(arguments)
          args = arguments.to_s.strip

          if args.empty?
            show_agents_list
            return
          end

          tokens = args.split(/\s+/)
          stop   = tokens.delete("--stop") ? true : false
          id     = tokens.shift

          if id.nil? || id.empty?
            show_agents_list
          elsif stop
            stop_agent(id)
          elsif tokens.first == "steer"
            steer_agent(id, dequote(tokens[1..].join(" ")))
          elsif tokens.first == "probe"
            probe_agent(id, dequote(tokens[1..].join(" ")))
          else
            show_agent_detail(id)
          end
        end

        # `/stop <id>` is the discoverable alias for the unguessable `/agents
        # <id> --stop` cancel syntax (FRICTION-4). A bare `/stop` teaches the
        # syntax and lists running subagents rather than erroring.
        def handle_stop_alias(arguments)
          id = arguments.to_s.strip.split(/\s+/).first
          if id.nil? || id.empty?
            @ui.info("Stop a running subagent: /stop <id> (same as /agents <id> --stop).")
            handle_agents("")
          else
            handle_agents("#{id} --stop")
          end
          :handled
        end

        # child->parent ASK_PARENT answer: /reply <id> <answer>. Resolves the
        # child's ask gate (Run::ApprovalGate#decide) so a BLOCKING ask unwinds with
        # the answer as its tool result, and ALSO pushes the answer onto the child's
        # steer queue so a NON-BLOCKING ask folds it in at its next turn boundary.
        # Either way the answer PERSISTS in the child's context. With no inline
        # answer, falls back to an interactive prompt (the ◆ takeover, like the
        # approval menu). Clears the blocked state and unblocks the tree.
        def handle_reply(arguments)
          tokens = arguments.to_s.strip.split(/\s+/)
          id     = tokens.shift
          if id.nil? || id.empty?
            show_blocked_agents
            return
          end

          # /reply is UNSCOPED: the human is the ultimate supervisor and may answer
          # ANY blocked node — one waiting on the human (:blocked_on_human) OR one
          # waiting on its agent-parent (:blocked_on_parent), if the human chooses
          # to step in.
          entry = Tools::BackgroundTasks.instance.find(id)
          if entry.nil?
            @ui.error("no background subagent with id #{id}. #{RESET_HINT}")
            return
          end
          unless %i[blocked_on_human blocked_on_parent].include?(entry.status)
            @ui.error("#{id} is not waiting on you.")
            return
          end

          answer = dequote(tokens.join(" "))
          answer = prompt_reply_answer(entry) if answer.to_s.strip.empty?
          if answer.to_s.strip.empty?
            @ui.info("No answer given — #{id} is still waiting.")
            return
          end

          deliver_reply(entry, answer)
        end

        private

        # parent->child STEER: a fire-and-forget note that enters the child's
        # context at its next turn boundary (Loop#inject_steered_input). Pushes onto
        # the child's steering queue via BackgroundTasks#steer — the SAME wire the
        # human uses to steer the parent. Echoed with the existing steer vocabulary
        # (▸, "enters child context") + a card repaint so the parked note shows.
        def steer_agent(id, text)
          if text.to_s.strip.empty?
            @ui.error(%(usage: /agents #{id} steer "your note"))
            return
          end

          if Tools::BackgroundTasks.instance.steer(id, text)
            @ui.info("steer ▸ #{id} ← #{truncate(text, 80)}  (parked · enters child context next turn)")
            @ui.set_subagent_cards if @ui.respond_to?(:set_subagent_cards)
          else
            @ui.error("cannot steer #{id} — no such running subagent. #{RESET_HINT}")
          end
        end

        # parent->child PROBE: an EPHEMERAL read-only peek. Snapshots the child's
        # current messages, runs ONE side-inference ([child messages] + question) on
        # the child's own model, prints the answer in a dashed "ephemeral · not
        # saved" aside, and DISCARDS it — nothing is appended to the child's
        # history, nothing enters the timeline. The absence of any saved/timeline
        # entry is itself the signal that the peek changed nothing.
        def probe_agent(id, question)
          if question.to_s.strip.empty?
            @ui.error(%(usage: /agents #{id} probe "your question"))
            return
          end

          entry = Tools::BackgroundTasks.instance.find(id)
          unless entry
            @ui.error("cannot probe #{id} — no such subagent. #{RESET_HINT}")
            return
          end

          @ui.info(pastel.dim("┄┄ probe → #{id} ┄┄  (ephemeral · not saved · child trajectory unchanged)"))
          # A probe answers from the child's context AT THIS INSTANT; right after
          # spawn that context is still empty and the child honestly says it isn't
          # working on anything yet — hint so that doesn't read as broken (#112).
          if entry.tool_count.to_i.zero?
            @ui.info(pastel.dim("   (snapshot at this instant — the child just started and its " \
                                "context is still empty; probe again in a moment)"))
          end
          @ui.info("?  #{question}")
          # The peek is a synchronous side-inference (seconds of model wait) with
          # nothing streaming — show the same thinking row /probe got in #58 so
          # the gap before the ⟵ answer never looks frozen (#146). TTY only;
          # Null/API adapters and pipes stay silent.
          probe_thinking_started(@ui)
          answer = begin
            Tools::SubagentProbe.new.peek(entry: entry, question: question)
          ensure
            probe_thinking_finished(@ui)
          end
          @ui.info("⟵  #{answer}")
          @ui.info(pastel.dim("┄┄ end probe (nothing was saved to #{id}) ┄┄"))
        end

        # The interactive ◆ takeover for /reply with no inline answer — mirrors the
        # approval menu (composer-suspend, ◆ glyph) so answering an ask_parent feels
        # exactly like answering an approval, a pattern the user already knows.
        #
        # Content of the affordance (LOCKED "options if present, else free text"):
        #   * the asking child supplied `options:` → an arrow-SELECT of those
        #     concrete options PLUS a trailing "✎ Answer (type)…" entry that opens
        #     the free-text field. Reuses @ui.select (the same TTY::Prompt picker
        #     /sessions resume uses) under run_in_terminal.
        #   * no options → the original free-text @ui.ask, but offered as a
        #     [Answer / Dismiss] choice first so Esc/Dismiss cleanly CANCELS this
        #     answer (the child stays blocked) instead of forcing a blank line.
        # Returns the chosen/typed answer, or "" when the human cancels (Esc /
        # Dismiss / blank) — answer_one_human then leaves the child parked.
        def prompt_reply_answer(entry)
          @ui.info("")
          @ui.info("◆ #{entry.id} (#{entry.subagent}) asks — everything is waiting on this")
          @ui.info("   ❓ #{entry.ask_question}")
          options = Array(entry.ask_options)
          options.empty? ? prompt_free_or_dismiss : prompt_pick_option(options)
        end

        # No options: [Answer / Dismiss]. "Answer" opens the free-text field;
        # "Dismiss" (or Esc, which #select returns as nil) cancels — child stays
        # blocked. A UI without #select (scripted/legacy) falls straight through
        # to the free-text @ui.ask so the existing behaviour is preserved.
        def prompt_free_or_dismiss
          return @ui.ask("✎ your answer › ").to_s unless @ui.respond_to?(:select)

          choice = @ui.select("Answer this subagent?",
                              [["✎ Answer (type)…", :answer], ["Dismiss (leave blocked)", :dismiss]])
          return "" unless choice == :answer

          @ui.ask("✎ your answer › ").to_s
        end

        # Options present: arrow-select one of them, or the trailing free-text
        # entry. Esc (nil from #select) cancels. Reuses @ui.select; a UI without
        # it answers free-text so scripted callers keep working.
        def prompt_pick_option(options)
          return @ui.ask("✎ your answer › ").to_s unless @ui.respond_to?(:select)

          choices = options.map { |o| [o, o] }
          choices << ["✎ Answer (type)…", :__free__]
          choice = @ui.select("Pick an answer for the subagent:", choices)
          return "" if choice.nil? # Esc / cancelled
          return @ui.ask("✎ your answer › ").to_s if choice == :__free__

          choice
        end

        # Routes the answer back DOWN to the child: decide the gate (unblocks a
        # blocking ask with the answer as its tool result) and push it onto the
        # steer queue (a non-blocking ask folds it in next turn). Then clear the
        # blocked state and repaint so the ⛔ marker clears.
        def deliver_reply(entry, answer)
          # The ONE shared answer wire (also used by the model-callable
          # answer_child tool): decide the gate + push the steer note + clear the
          # blocked state, all in BackgroundTasks#deliver_answer.
          # H5 — deliver_answer reports HONESTLY now: false when the child has
          # already finished and neither delivery path landed. Say so instead of
          # the false "resumes at its next turn" — there is no next turn.
          delivered = Tools::BackgroundTasks.instance.deliver_answer(entry.id, answer)
          if delivered
            @ui.info("↳ answered #{entry.id}: #{truncate(answer, 80)}")
            @ui.info("✓ tree unblocked · #{entry.id} resumes at its next turn")
          else
            @ui.info("↳ answer to #{entry.id}: #{truncate(answer, 80)}")
            @ui.error("⚠ not delivered — #{entry.id} already finished; it never saw your answer.")
          end
          @ui.set_subagent_cards if @ui.respond_to?(:set_subagent_cards)
        end

        # Lists the children currently blocked on the human (the /reply with no id
        # case) so the user can see who is waiting and on what.
        def show_blocked_agents
          blocked = Tools::BackgroundTasks.instance.awaiting_human
          if blocked.empty?
            @ui.info("No subagent is waiting on you.")
            return
          end

          @ui.info(pastel.red("⛔ #{blocked.size} subagent waiting on you:"))
          blocked.each do |e|
            @ui.info("  #{e.id} · #{e.subagent}: #{truncate(e.ask_question, 80)}")
          end
          @ui.info("/reply <id> <answer> to answer")
        end

        # Strips a single pair of wrapping double/single quotes from a steer/probe
        # argument so `steer "be terse"` lands as `be terse`, not `"be terse"`.
        def dequote(text)
          t = text.to_s.strip
          if t.length >= 2 && ((t.start_with?(%(")) && t.end_with?(%("))) || (t.start_with?("'") && t.end_with?("'")))
            return t[1..-2]
          end

          t
        end

        def show_agents_list
          entries = Tools::BackgroundTasks.instance.list
          if entries.empty?
            @ui.info("No background subagents. The agent starts them with its `task` tool;")
            @ui.info("they run while you keep working. They'll appear here when it does.")
            return
          end

          rows = entries.map do |e|
            [e.id, agent_status_icon(e.status), agent_label(e), agent_elapsed(e)]
          end
          @ui.table(headers: %w[ID Status Task Elapsed], rows: rows)
          @ui.info("/agents <id> for output   ·   /agents <id> --stop to cancel")
        end

        def show_agent_detail(id)
          entry = Tools::BackgroundTasks.instance.find(id)
          unless entry
            @ui.error("no background subagent with id #{id}. #{RESET_HINT}")
            return
          end

          case entry.status
          when :needs_approval
            # Option 2: a parked child is waiting on THIS human. Lead with the
            # interactive approve/deny prompt that resolves its gate.
            resolve_agent_approval(entry)
          when :running
            # #71 live drill-in: expand to the task summary + the recent-activity
            # ring, tailing the registry live until the user stops watching.
            watch_agent(entry)
          else
            show_agent_result(entry)
          end
        end

        # Static detail for a finished (done/failed) task — the full result/error,
        # as before.
        def show_agent_result(entry)
          @ui.info("#{entry.id}  #{agent_status_icon(entry.status)}  ·  #{entry.subagent}")
          @ui.info("task: #{truncate(entry.prompt, 200)}")
          @ui.separator
          case entry.status
          when :failed
            @ui.error(entry.error.to_s.empty? ? "(failed, no error message)" : entry.error.to_s)
          when :stopped
            show_stopped_summary(entry)
          else
            render_agent_report(entry.result.to_s)
          end
        end

        # The child's final report is markdown (it is a model answer): render it
        # through the SAME pipeline assistant answers use instead of dumping
        # literal `##`/`**` into the transcript (#139). Adapters without the
        # markdown seam (Null/API) keep the plain info fallback.
        def render_agent_report(result)
          return @ui.info("(no output)") if result.empty?

          if @ui.respond_to?(:commit_markdown_block)
            @ui.commit_markdown_block(result)
          else
            @ui.info(result)
          end
        end

        # A stopped child may have COMPLETED side effects before the stop (#150):
        # "no result" alone led the parent/human to assert nothing was produced
        # while an approved write was already on disk. Surface the tool count and
        # the registry's activity tail as ground truth.
        def show_stopped_summary(entry)
          count = entry.tool_count.to_i
          if count.zero?
            @ui.info("(stopped at your request before it ran any tools — no result)")
          else
            @ui.info("(stopped at your request after #{count} tool#{"s" if count != 1} had already run — " \
                     "completed tools' side effects may exist)")
            Array(entry.activity_log).last(3).each { |line| @ui.info("  #{line}") }
          end
        end

        # #71 — LIVE drill-in for a running subagent. Renders the task summary and
        # the recent-activity ring (read live from the registry, which the child's
        # UI::SubagentView keeps fresh), refreshing in place until the user presses a
        # key (Esc/Enter/q) or the task ends. Off an interactive terminal (#ask
        # returns nil — Null/API/pipe) it degrades to a SINGLE snapshot so the
        # non-interactive paths and unit tests never block on a redraw loop.
        def watch_agent(entry)
          render_agent_watch(entry)
          return unless interactive_terminal?

          @ui.info("(watching live — press Enter/Esc to stop, /agents #{entry.id} --stop to cancel)")
          watch_loop(entry.id)
        end

        # Renders ONE watch frame: header + task + the recent: ring + the live
        # output: tail. Public-ish snapshot shape reused per refresh tick. The
        # recent ring is the registry's bounded activity_log, plus the live
        # last_activity as the trailing ● line.
        def render_agent_watch(entry)
          @ui.info("#{entry.id}  #{agent_status_icon(entry.status)}  ·  #{entry.subagent}  ·  #{agent_elapsed(entry)}")
          @ui.info("task: #{truncate(entry.prompt, 120)}")
          @ui.info("recent:")
          Array(entry.activity_log).last(5).each { |line| @ui.info("  #{line}") }
          last = entry.last_activity.to_s
          @ui.info("  #{pastel.yellow("●")} #{last}") unless last.empty?
          render_agent_output_tail(entry)
        end

        # #5 — the live output: block under the ring: the tail of the CURRENTLY
        # RUNNING tool's streamed output (the registry's bounded output_tail,
        # fed by the child's UI::SubagentView#tool_chunk and wiped at
        # tool_finished), so a long shell call shows its lines as they print
        # instead of a frozen frame. Renders nothing when no tool is mid-run or
        # it hasn't produced output yet; the buffer's empty last slot just means
        # the latest line is complete, so it is dropped, not rendered.
        def render_agent_output_tail(entry)
          lines = Array(entry.output_tail)
          lines = lines[0..-2] if lines.last.to_s.empty?
          return if lines.empty?

          @ui.info("output:")
          lines.last(Tools::BackgroundTasks::OUTPUT_TAIL_MAX).each do |line|
            @ui.info("  #{pastel.dim("│")} #{truncate(line, 120)}")
          end
        end

        # The live refresh loop for #watch_agent. Polls the registry and re-renders
        # a frame each tick until the task leaves :running or the user hits a key.
        # Kept deliberately simple (a periodic re-render of the snapshot, not a
        # full-screen redraw) to stay scroll-native and avoid a second raw-mode
        # rendering subsystem. Bounded so it can never hang the REPL.
        def watch_loop(id, ticks: 600, interval: 0.5)
          ticks.times do
            break if key_pressed?(interval)

            entry = Tools::BackgroundTasks.instance.find(id)
            break if entry.nil? || entry.status != :running

            @ui.separator
            render_agent_watch(entry)
          end
          final = Tools::BackgroundTasks.instance.find(id)
          @ui.info("(stopped watching #{id})") if final && final.status == :running
        end

        # Option 2 — resolve a parked child's approval. Shows the command and asks
        # Approve once / Approve always / Deny; the answer resolves the child's
        # gate (the child's #confirm returns it). "always" approves AND persists via
        # the parent CLI's allowlist (the same path an inline approval uses), so the
        # child — and future calls — proceed without re-prompting.
        def resolve_agent_approval(entry)
          gate = entry.approval_gate
          unless gate
            @ui.info("#{entry.id} is no longer waiting on approval.")
            return
          end

          @ui.info("#{entry.id}  #{agent_status_icon(entry.status)}  ·  #{entry.subagent}")
          @ui.info("needs approval to run:")
          @ui.info("  #{entry.approval_command.to_s.empty? ? entry.approval_question : entry.approval_command}")
          choice = ask_approval_answer(entry)
          return if choice.nil?

          decision =
            case choice
            when :always_command then persist_agent_always(entry)
                                      true
            when :once           then true
            when :deny_explain   then deny_with_explanation(entry)
            else                      false
            end
          gate.decide(entry.approval_id, decision)
          @ui.info(decision ? "Approved #{entry.id}." : "Denied #{entry.id}.")
        end

        # Renders the UNIFIED arrow-key approval menu (TUI-6) for a parked
        # subagent: the SAME component the main-agent/MCP approval uses
        # (UI::CLI#subagent_approval_choice → #approval_menu), replacing the old
        # flat `[o]nce/[a]lways/[n]o deny` line where any non-decision keystroke
        # — including a slash command typed to inspect first — was silently
        # treated as a DENY. The menu can only return a real decision symbol, so
        # a stray keystroke can never resolve the gate by accident.
        #
        # A background event (another child's completion fold-in) landing while
        # the prompt is open can abort the underlying TTY read; the menu then
        # returns nil, which is NOT a decision — re-render up to
        # APPROVAL_ASK_ATTEMPTS times, and on a persistent abort leave the child
        # parked (never auto-deny, #144) so `/agents <id>` re-opens the prompt.
        # A UI without the unified menu (legacy/scripted) falls back to nil.
        def ask_approval_answer(entry)
          return nil unless @ui.respond_to?(:subagent_approval_choice)

          APPROVAL_ASK_ATTEMPTS.times do
            choice = @ui.subagent_approval_choice
            return choice if choice
          end
          @ui.info("no answer read — #{entry.id} is still waiting; /agents #{entry.id} to decide.")
          nil
        end

        # The "Deny & tell the agent why" path: collect a one-line reason and
        # hand it to the child as a steer note (best-effort) so the subagent
        # learns WHY its action was refused instead of a bare deny. Always
        # returns false — the gate is denied either way; the reason is advisory.
        def deny_with_explanation(entry)
          reason = @ui.respond_to?(:ask) ? @ui.ask("why deny? (sent to the agent): ").to_s.strip : ""
          Tools::BackgroundTasks.instance.steer(entry.id, "[approval denied by human] #{reason}") unless reason.empty?
          false
        rescue StandardError
          false
        end

        # Persists an "approve always" for a parked subagent's command via the same
        # session allowlist the inline CLI approval uses, so the decision survives
        # and future identical calls (parent or child) skip the prompt.
        def persist_agent_always(entry)
          scope = "#{entry.subagent}:#{entry.approval_command}"
          Run::SessionApprovalCache.instance.remember(@ui.respond_to?(:session_id) ? @ui.session_id : nil, scope,
                                                      "session")
        rescue StandardError
          nil
        end

        # True when the REPL owns a real interactive terminal (so a live watch /
        # keypress poll makes sense). Off a TTY we render a single snapshot.
        def interactive_terminal?
          $stdin.respond_to?(:tty?) && $stdin.tty? && $stdout.respond_to?(:tty?) && $stdout.tty?
        rescue StandardError
          false
        end

        # Non-blocking-ish single-key poll: waits up to +timeout+s for any key.
        # Used to let the user stop the live watch with a keypress. Best-effort:
        # returns false (keep watching) on any terminal hiccup so the bounded loop
        # still terminates on its tick budget.
        def key_pressed?(timeout)
          return false unless interactive_terminal?

          ready = $stdin.wait_readable(timeout)
          return false unless ready

          $stdin.read_nonblock(1)
          true
        rescue StandardError
          false
        end

        def stop_agent(id)
          registry = Tools::BackgroundTasks.instance
          entry    = registry.find(id)
          unless entry
            @ui.error("no background subagent with id #{id}. #{RESET_HINT}")
            return
          end

          unless %i[running needs_approval blocked_on_human blocked_on_parent].include?(entry.status)
            @ui.info("#{id} already #{entry.status} — nothing to stop.")
            return
          end

          # A child parked on a human approval or an ask_parent is blocked in its
          # gate's wait; the shared #stop_entry cancels the gates so it wakes
          # (Interrupted → deny/cancel) and unwinds instead of holding its thread
          # until the bound, runs the stop-cascade so every DESCENDANT parked on a
          # blocking ask unwinds too (S5a — no orphaned blocked grandchild), marks
          # the stop FIRST so the very next /agents list shows ◌ stopping instead
          # of a stale ● running (#108) and the worker's terminal write records the
          # unwind as :stopped, not ✗ failed (#13), then flips the runner token. The
          # SAME body the parent-teardown #cancel_all uses — one implementation.
          registry.stop_entry(entry)
          @ui.success("Stop requested for #{id} (#{entry.subagent}); it unwinds at its next checkpoint.")
        end

        # `<glyph> <word>` for a subagent's state, with a SPACE between glyph and
        # word and the glyph colored by state (#86): amber ● running, red ✗ failed,
        # green ✓ done — instead of a same-color, glued "●running".
        def agent_status_icon(status)
          glyph, word, color =
            case status
            when :running          then ["●", "running", :yellow]
            when :stopping         then ["◌", "stopping", :yellow]
            when :stopped          then ["⊘", "stopped", :yellow]
            when :needs_approval   then ["●", "approval", :yellow]
            when :blocked_on_human then ["⛔", "waiting on you", :red]
            when :blocked_on_parent then ["◷", "waiting on parent", :cyan]
            when :failed then ["✗", "failed", :red]
            else ["✓", "done", :green]
            end
          "#{pastel.public_send(color, glyph)} #{word}"
        end

        # subagent name + the DISTINGUISHING detail for the list label (#127). For
        # a running task the live last_activity is the most distinguishing field
        # (two "explore: summarize lib/…" tasks differ by what they're doing NOW),
        # so prefer it; otherwise a wider (80-char) slice of the prompt's first
        # line so the tail — often the distinguishing path/arg — survives instead
        # of being cut at 40.
        def agent_label(entry)
          if %i[running needs_approval stopping].include?(entry.status) && !entry.last_activity.to_s.empty?
            return "#{entry.subagent}: #{truncate(entry.last_activity, 80)}"
          end

          prompt = truncate_middle(entry.prompt.to_s.lines.first.to_s.strip, 80)
          prompt.empty? ? entry.subagent : "#{entry.subagent}: #{prompt}"
        end

        # Middle truncation for the /agents Task label (#14): similarly-phrased
        # delegations share their HEAD ("Summarize the contents of lib/…") while
        # the distinguishing detail — the path/arg — sits at the TAIL, so a
        # head-only cut renders concurrent tasks identical. Keep both ends,
        # elide the middle.
        def truncate_middle(text, max)
          s = text.to_s.gsub(/\s+/, " ").strip
          return s if s.length <= max

          head = (max - 1) * 2 / 3
          tail = max - 1 - head
          "#{s[0, head]}…#{s[-tail, tail]}"
        end

        def agent_elapsed(entry)
          finish = entry.finished_at || Time.now
          return "" unless entry.started_at

          Rubino::Util::Duration.human_duration(finish - entry.started_at)
        end

        def pastel
          @pastel ||= Pastel.new
        end

        def truncate(text, max)
          s = text.to_s.gsub(/\s+/, " ").strip
          s.length > max ? "#{s[0, max - 1]}…" : s
        end
      end
    end
  end
end
