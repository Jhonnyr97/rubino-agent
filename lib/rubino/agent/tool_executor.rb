# frozen_string_literal: true

require "securerandom"

module Rubino
  module Agent
    # The "what survived" phrase in a compression recovery pointer, per content
    # type (anything else — logs — keeps the failures + summary).
    COMPRESSION_KEPT_NOTES = { code: "signatures + small bodies kept",
                               diff: "all +/- changes + headers kept",
                               json: "schema + error/outlier rows kept" }.freeze

    # Executes tool calls with approval checks and result formatting.
    class ToolExecutor # rubocop:disable Metrics/ClassLength
      # The Loop registers its count+persist sink here after construction (the
      # executor is built first so the adapter/ToolBridge can share it). See
      # Loop#handle_tool_result.
      attr_writer :on_result

      # True once any tool was BLOCKED for approval in a non-interactive session
      # (#260): a write/edit/shell that needed a prompt no one could answer. The
      # one-shot CLI reads this after the run to exit NON-ZERO so CI/automation
      # fails loudly instead of treating a silently-skipped action as success.
      def blocked_for_approval?
        @blocked_for_approval == true
      end

      def initialize(registry:, approval_policy:, ui:, config:,
                     tool_call_repository: Tools::ToolCallRepository.new,
                     cancel_token: nil, read_tracker: nil, event_bus: nil,
                     on_result: nil, session_id: nil)
        @registry             = registry
        @approval_policy      = approval_policy
        @ui                   = ui
        @config               = config
        @tool_call_repository = tool_call_repository
        @cancel_token         = cancel_token
        # Session the audit row is attributed to. The tool_calls table requires
        # a non-null session_id FK, so without this every audit insert violated
        # the constraint and was swallowed by the repository's rescue — leaving
        # the table empty on every execution, streaming or not (#262).
        @session_id           = session_id
        # Optional sink the Loop registers so a tool that runs on the STREAMING
        # path (ruby_llm dispatches it mid-stream via ToolBridge → straight into
        # #execute, never returning through Loop#execute_tool_calls) is still
        # counted in the turn summary and persisted as a `tool` message. Called
        # once per completed/denied tool with (name:, arguments:, call_id:,
        # result:). The non-streaming path routes through the same sink so the
        # count/persist happens in exactly one place regardless of mode.
        @on_result            = on_result
        # Optional event bus so this executor emits TOOL_STARTED/TOOL_FINISHED
        # for the API mode timeline. ToolBridge already emits these when no
        # executor is wired (test/one-shot path); the production path went
        # through here and dropped them, so the web UI timeline never saw
        # the tool call as a discrete event.
        @event_bus            = event_bus
        # One tracker shared across every tool call so the read registered by
        # ReadTool is visible to a later EditTool. The production path
        # (Interaction::Lifecycle) injects the SESSION-scoped tracker so the
        # gate spans turns (#151). Default to a fresh tracker if the caller
        # didn't supply one; an isolated unit test can pass
        # `read_tracker: nil` to skip the gate.
        @read_tracker         = read_tracker.equal?(false) ? nil : (read_tracker || Tools::ReadTracker.new)
      end

      # Executes a single tool call, returns a Tools::Result.
      def execute(name:, arguments:, call_id:)
        # Normalize arguments to symbol keys ONCE, before any downstream consumer
        # (live_card_header, preview_arguments, tool.call, SkillTool#call) reads
        # them. RubyLLM::Tool#call does the same transform_keys(&:to_sym), so
        # doing it here makes it idempotent and removes every string-key fallback.
        arguments = arguments.transform_keys(&:to_sym) if arguments.respond_to?(:transform_keys)

        # Cancellation checkpoint BEFORE the tool runs (#335b). On the streaming
        # path ruby_llm dispatches tool calls mid-stream through ToolBridge into
        # here, and the loop's per-iteration #check! is far above us — so without
        # this a cancel that arrived while a PREVIOUS tool was running (or during
        # the thinking phase) wouldn't be observed until the model resumed
        # streaming, letting the next tool fire after the user already hit
        # interrupt. Raising here halts the in-flight turn at the next tool
        # boundary, the soonest safe checkpoint, so "esc to interrupt" actually
        # stops the agent instead of letting it run one more tool.
        @cancel_token&.check!

        tool = @registry.find(name)
        raise ToolError, "Unknown tool: #{name}" unless tool

        # Background review (Hermes-style post-turn fork, BackgroundReviewJob):
        # the forked review agent may ONLY dispatch the whitelisted skill/memory
        # tools. The request still CARRIES the full tools[] so the prompt prefix
        # stays byte-identical to the parent turn's warm KV cache — only DISPATCH
        # is restricted here. A non-whitelisted call is denied-by-policy; a
        # whitelisted one is a trusted, sandboxed background write (HOME/skills +
        # memory store only) and is pre-approved (decision :allow), so it never
        # reaches the interactive approval gate / #260 headless fail-closed floor
        # that a human-less thread can't clear. See Rubino.review_toolset.
        review_allowed = Rubino.review_toolset
        if review_allowed && !review_allowed.include?(name)
          denied = Tools::Result.denied(name: name, call_id: call_id, reason: :policy)
          record_denied(name: name, call_id: call_id, arguments: arguments,
                        result: denied, reason: "review-not-whitelisted")
          return finish(name, arguments, call_id, denied)
        end

        decision = review_allowed ? :allow : @approval_policy.decide(tool, arguments: arguments)
        case decision
        when :deny
          # A policy denial must NOT read "denied by user" to the model — the
          # policy records why it fired (#last_deny_reason) and the Result
          # maps it to a reason-specific message, so a child agent never
          # blames the human for an automatic deny (#143).
          denied = Tools::Result.denied(name: name, call_id: call_id, reason: policy_deny_reason)
          record_denied(name: name, call_id: call_id, arguments: arguments,
                        result: denied, reason: "policy-denied")
          # A policy deny (hardline / permissions:deny / doom-loop) previously
          # rendered NO live card — only the footer's "N denied" counter — so the
          # operator couldn't see WHICH command was auto-refused or why. Emit the
          # started+finished pair now so it surfaces as a labelled card
          # (`● shell rm -rf /` → `└ ✗ shell denied — not executed [hardline]`).
          # The :ask user-"No" path renders via #confirm and is untouched.
          emit_started(name, arguments, call_id)
          emit_finished(name, result: denied, duration_ms: 0, arguments: arguments)
          return finish(name, arguments, call_id, denied)
        when :ask
          # Headless FAIL-CLOSED floor (#260). A tool the policy wants to ASK
          # about — a write/edit, or a shell command not covered by the
          # permissions allowlist / read-only auto-allow — cannot be approved
          # when there is no interactive session (one-shot `rubino prompt`/`-q`,
          # a pipe, a gate-less embed). Auto-running it (the old UI::Null#confirm
          # → true bug) is the prompt-injection→RCE foot-gun; hanging on a prompt
          # no one can answer is the opencode bug. So DENY with a clear,
          # single-line block message and record the block so the run can exit
          # non-zero. Anything the user already allowlisted resolved to :allow
          # before reaching here, so this never regresses a configured command.
          unless @ui.interactive?
            @blocked_for_approval = true
            message = approval_block_message(tool, arguments)
            @ui.warning(message) if @ui.respond_to?(:warning)
            # Let the headless adapter latch the block so the one-shot CLI can
            # exit non-zero (#260) without threading a flag up through the loop.
            @ui.tool_blocked(message) if @ui.respond_to?(:tool_blocked)
            blocked = Tools::Result.denied(name: name, call_id: call_id, reason: :noninteractive)
            record_denied(name: name, call_id: call_id, arguments: arguments,
                          result: blocked, reason: "noninteractive-blocked")
            return finish(name, arguments, call_id, blocked)
          end

          unless request_approval(tool, arguments)
            denied = Tools::Result.denied(name: name, call_id: call_id, reason: :user)
            record_denied(name: name, call_id: call_id, arguments: arguments,
                          result: denied, reason: "user-denied")
            return finish(name, arguments, call_id, denied)
          end
        end

        # Widen-on-approval (Claude-Code-aligned): a structured write whose
        # target sits OUTSIDE the workspace was routed to :ask by the policy
        # (step 8a) and just cleared approval — or was auto-allowed under yolo.
        # Add the target's directory to the workspace roots NOW, before the tool
        # runs, so both the tool's own writable_workspace? guard and the OS
        # write-jail (both read Workspace.roots live) let the write land, instead
        # of the dead-end "refusing to access" the boundary used to return. No-op
        # for an in-workspace write. Runs on EVERY proceed path (approved :ask
        # and yolo :allow); the headless block and user-deny paths returned above,
        # so an unapproved out-of-workspace write is never widened.
        widen_workspace_if_needed(tool, arguments)

        # Warn-not-block doom-loop guard (#414): when the detector tripped but
        # hard_stop is off (the default), the call is ALLOWED — surface a
        # one-time warning so a stuck autopilot is visible without hard-denying a
        # legitimate repeated/idempotent call.
        if @approval_policy.respond_to?(:doom_loop_warning) &&
           @approval_policy.doom_loop_warning && @ui.respond_to?(:warning)
          @ui.warning(
            "doom-loop guard: '#{name}' called with identical arguments repeatedly — " \
            "proceeding (set doom_loop.hard_stop:true to block)"
          )
        end

        notify_yolo_if_applicable(tool, arguments)
        emit_started(name, arguments, call_id)
        started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        result = nil
        begin
          result = run_tool(tool, name: name, arguments: arguments, call_id: call_id)
          # Hot retry on sandbox denial (Codex-style): when the OS write-jail
          # denied the command, ask for escalation approval and re-run
          # unsandboxed — zero extra model round-trips. Only for foreground
          # shell commands with the jail proven enforcing and the escape hatch
          # open (#74 write-jail attribution + §B escalation).
          if (escalated = try_escalation(result, tool, arguments, call_id))
            result = escalated
          end
        ensure
          duration_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started_at) * 1000).round
          emit_artifact(result) if result.respond_to?(:artifact) && result&.artifact
          emit_finished(name, result: result, duration_ms: duration_ms, arguments: arguments)
        end
        finish(name, arguments, call_id, result)
      end

      private

      # Single exit point: notifies the Loop's on_result sink (count + persist)
      # for every completed/denied tool, then returns the result unchanged. This
      # is the one place both the streaming (ToolBridge → #execute) and the
      # non-streaming (Loop#execute_tool_calls → #execute) paths funnel through,
      # so the turn-summary count and the `tool` message rows stay accurate
      # regardless of streaming mode. Best-effort: a sink failure must not take
      # down the tool call the model is waiting on.
      # Drill-in telemetry for the recovery channel rides here: recovery is now
      # ONLY via retrieve_output (no cat-able path), so a retrieve_output call IS
      # the deliberate recovery — emit compression.drill_in with its id. Makes the
      # counter meaningful (real recoveries) and unbypassable by a shell
      # sed/grep/cat, which the old read-only detector missed. (:code's real-file
      # offset-read drill-in detection in ReadTool stays as-is.)
      def finish(name, arguments, call_id, result)
        log_retrieve_drill_in(arguments) if name == "retrieve_output"
        @on_result&.call(name: name, arguments: arguments, call_id: call_id, result: result)
        result
      rescue StandardError => e
        Rubino.logger&.warn(event: "tool_executor.on_result_failed", error: e.message)
        result
      end

      def run_tool(tool, name:, arguments:, call_id:)
        tool.cancel_token = @cancel_token if tool.respond_to?(:cancel_token=)
        tool.read_tracker = @read_tracker if tool.respond_to?(:read_tracker=)

        # ── Inline tool adapter (live_card opt-in) ────────────────────
        # When the tool class declares `live_card`, create an adapter and
        # register it in BackgroundTasks so it appears in the multiplexer
        # dropdown WHILE the tool runs. The adapter's output buffer is fed
        # from the same stream_chunk callback — the existing ⏎ attach then
        # shows the inline tool's output like any shell/subagent entry.
        inline_adapter = nil
        if tool.class.respond_to?(:live_card?) && tool.class.live_card?
          begin
            header = tool.class.live_card_header.call(arguments)
          rescue StandardError => e
            Rubino.logger&.warn(event: "tool_executor.live_card_header_failed",
                                error: e.message, error_class: e.class.name)
            header = name.to_s
          end
          defer_after = tool.class.respond_to?(:live_card_after) ? tool.class.live_card_after : nil
          inline_adapter = Tools::InlineToolAdapter.new(
            id: "il_#{SecureRandom.hex(4)}",
            tool_name: name,
            command_hint: header.to_s,
            after: defer_after&.to_f
          )
          Tools::BackgroundTasks.instance.register_inline(inline_adapter)
        end

        streamed = false
        last_progress_at = nil
        # Install stream_chunk when the UI/event_bus needs it OR we have an
        # inline adapter that needs its buffer fed (even in test environments
        # where the UI doesn't respond to tool_chunk).
        if tool.respond_to?(:stream_chunk=) &&
           (@ui.respond_to?(:tool_chunk) || @event_bus || inline_adapter)
          tool.stream_chunk = lambda do |chunk|
            streamed = true
            # Feed the inline adapter's buffer. When deferred, #emit
            # returns nil (buffer only); otherwise it returns the chunk
            # to stream (or the accumulated drain when visibility flips).
            # Without an adapter, the chunk passes through unchanged.
            ui_chunk = inline_adapter ? inline_adapter.emit(chunk) : chunk
            if ui_chunk
              # Read stream_kind LAZILY: the tool only knows its output kind
              # (e.g. :diff for `git diff`) once #call has inspected the command,
              # which happens AFTER this lambda is installed.
              kind = tool.respond_to?(:stream_kind) ? (tool.stream_kind || :plain) : :plain
              @ui.tool_chunk(name, ui_chunk, kind: kind) if @ui.respond_to?(:tool_chunk)
              # Mirror the chunk onto the bus so the API/SSE stream isn't silent
              # during a long tool call: the Recorder maps TOOL_PROGRESS to a
              # `tool.progress` event, which resets the idle watchdog. Without
              # this a busy tool (a long shell stream, or an aux-LLM-backed tool,
              # no run-events) is killed at the 300s idle timeout. Throttled so a
              # chatty tool (shell streaming thousands of stdout lines) doesn't
              # write a DB row + SSE frame per line — one heartbeat per interval
              # is enough to keep the watchdog satisfied.
              last_progress_at = emit_tool_progress(name, ui_chunk, last_progress_at) if @event_bus
            end
          end
        end
        # Attribute the memory write to the parent session when one is already
        # bound (e.g. by the review fork), so facts mined by a disposable child
        # review session are attached to the triggering parent. Otherwise stamp
        # with the current session id (direct user-initiated memory writes).
        raw = if Rubino.memory_source_session_id
                tool.call(arguments)
              else
                Rubino.with_memory_source_session_id(@session_id) do
                  tool.call(arguments)
                end
              end
        if raw.is_a?(Tools::Result)
          raw = Tools::Result.new(
            name: name,
            call_id: call_id,
            output: Util::Output.truncate(raw.output, max_bytes: @config.dig("tool_output", "max_bytes"),
                                                      max_lines: @config.dig("tool_output", "max_lines"),
                                                      spill: ->(full) { spill_full_output(full, call_id) }),
            status: raw.status,
            error: raw.error,
            metrics: raw.metrics,
            error_code: raw.error_code,
            artifact: raw.artifact,
            transcript_card: raw.transcript_card?
          )
          record_audit(name: name, call_id: call_id, arguments: arguments,
                       result: raw, status: "completed")
          return raw
        end
        # Tools can return either a String (plain output) or a Hash carrying
        # {output:, metrics:, body:, body_kind:}. The Hash form lets a tool emit
        #   - a `metrics` one-liner for the done header ("42 lines · 0.1s")
        #   - a `body` block (diff, preview) printed inside the tool box
        #   - a `body_kind` (:diff | :plain) selecting the CLI coloring for body
        # without having to reverse-engineer them from the formatted output.
        if raw.is_a?(Hash)
          text         = raw[:output]     || raw["output"]
          metrics      = raw[:metrics]    || raw["metrics"]
          body         = raw[:body]       || raw["body"]
          body_kind    = raw[:body_kind]  || raw["body_kind"] || :plain
          error_code   = raw[:error_code] || raw["error_code"]
          artifact     = raw[:artifact]   || raw["artifact"]
          compress_hint = raw[:compress_hint] || raw["compress_hint"]
          label = raw[:label] || raw["label"]
          # Per-result redaction override: a tool whose class profile is weaker
          # than a SPECIFIC result needs (the unified `read`'s :code profile vs a
          # converted DOCUMENT, which is untrusted and must get the full :shell
          # pattern set) can escalate for that one result. Absent → class default.
          redaction_override = raw[:redaction_profile] || raw["redaction_profile"]
        else
          text = raw
          metrics = nil
          body = nil
          body_kind = :plain
          error_code = nil
          artifact = nil
          compress_hint = nil
          label = nil
          redaction_override = nil
        end
        # ── Redaction chokepoint (centralised here so no tool can leak secrets) ──
        # The resolved redactor instance reads the tool's redaction_profile and
        # scrubs both the model-facing `text` and the human-facing `body` before
        # they enter context, the compressor, or the UI. Shell streaming (below)
        # uses the same instance for live line-by-line redaction.
        redactor = Security::Redactor.resolve
        profile  = redaction_override ||
                   (tool.class.respond_to?(:redaction_profile) ? tool.class.redaction_profile : :shell)
        # Body redaction runs early (never compressed — human-facing only).
        body = redactor.redact(body, profile: profile) if body && profile != :none
        # Skip the body block when the tool already streamed its output line by
        # line via #tool_chunk: `body` is the SAME content (e.g. ShellTool's
        # Util::Output.preview of the captured stdout), so rendering it again
        # would duplicate every line in the timeline. Tools that don't stream
        # (read, grep, edit, glob) still render their body here.
        @ui.tool_body(body, kind: body_kind.to_sym) if body && !body.to_s.empty? && !streamed
        # Content-routed compression of the MODEL-FACING text only (never the
        # human `body` preview). The router detects the type and dispatches; a
        # diff/grep/short output passes through byte-identical. On a hit the FULL
        # original is spilled and a pointer appended so the model can read it back.
        text, metrics = maybe_compress(text, metrics: metrics, name: name,
                                             arguments: arguments, compress_hint: compress_hint,
                                             call_id: call_id)
        # Model-facing text redaction runs AFTER compression so a skeleton built
        # from raw_source (unredacted) doesn't reintroduce secrets the original
        # text path would mask. The common compression-OFF path is a single pass.
        text = redactor.redact(text, profile: profile) if text && profile != :none
        result = Tools::Result.success(
          name: name,
          call_id: call_id,
          output: Util::Output.truncate(text, max_bytes: @config.dig("tool_output", "max_bytes"),
                                              max_lines: @config.dig("tool_output", "max_lines"),
                                              spill: ->(full) { spill_full_output(full, call_id) }),
          metrics: metrics,
          error_code: error_code&.to_sym,
          artifact: artifact,
          label: label
        )
        record_audit(name: name, call_id: call_id, arguments: arguments,
                     result: result, status: "completed")
        result
      rescue Rubino::Interrupted
        # Defense in depth (#41): a user interrupt raised from ANY tool must
        # unwind the turn, never be recorded as a failed tool result. Folding it
        # into a generic Result.error lets the loop continue and send a malformed
        # continuation to the provider (rejected as "invalid params"). Re-raise so
        # the cancel path produces a clean `⎿ interrupted` instead.
        raise
      rescue StandardError => e
        result = Tools::Result.error(name: name, call_id: call_id, error: e.message)
        record_audit(name: name, call_id: call_id, arguments: arguments,
                     result: result, status: "failed", error: e.message)
        result
      ensure
        inline_adapter&.finish!
        if inline_adapter
          # RETAIN the adapter in the registry so its output buffer survives
          # beyond tool finish. finish! sets @live=false, which excludes it
          # from #running (Bug B's dropdown removal still works). The adapter
          # stays retrievable via find(id) — drilling into a finished inline
          # live_card re-paints output_all faithfully. A bounded reap (cap on
          # retained adapters) prevents unbounded growth; eviction runs on
          # register_inline (oldest finished first).
        end
        tool.cancel_token = nil if tool.respond_to?(:cancel_token=)
        tool.read_tracker = nil if tool.respond_to?(:read_tracker=)
        tool.stream_chunk = nil if tool.respond_to?(:stream_chunk=)
      end

      # Cap on per-event size we forward to SSE consumers (the web UI timeline,
      # CLI logs). Tools already truncate their textual output via
      # truncate_output for the model's eyes; this is a second guard so a
      # huge payload doesn't bloat the event bus / DB run_events rows.
      EVENT_PREVIEW_MAX = 4_000

      # Minimum gap between TOOL_PROGRESS heartbeats forwarded to the bus. Well
      # under the SSE idle watchdog window (300s) so the stream never goes
      # silent, but coarse enough that a chatty per-line tool doesn't flood the
      # event store. The first chunk always emits (nil last-emit time).
      TOOL_PROGRESS_INTERVAL = 5.0

      # Emits a throttled TOOL_PROGRESS heartbeat on the bus. Returns the
      # monotonic time of this emit (or the unchanged previous time when the
      # chunk was throttled) so the caller can track the cadence.
      def emit_tool_progress(name, chunk, last_at)
        now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        return last_at if last_at && (now - last_at) < TOOL_PROGRESS_INTERVAL

        @event_bus&.emit(Interaction::Events::TOOL_PROGRESS,
                         name: name, chunk: truncate_for_event(chunk.to_s))
        now
      end

      def emit_started(name, arguments, call_id = nil)
        sanitized = sanitize_arguments_for_event(arguments)
        @ui.tool_started(name, arguments: arguments, call_id: call_id) if @ui.respond_to?(:tool_started)
        payload = { name: name, arguments: sanitized }
        # Boundary event for delegation: tag the `task` call with the target
        # subagent name (+ the task prompt) so an SSE consumer (the web UI)
        # can render "delegated to X" without parsing the raw arguments. The
        # subagent's own inner events are NOT streamed in Phase 1 — boundary only.
        payload.merge!(subagent_tag(arguments)) if name == "task"
        @event_bus&.emit(Interaction::Events::TOOL_STARTED, **payload)
      end

      def emit_finished(name, result: nil, duration_ms: nil, arguments: nil)
        @ui.tool_finished(name, result: result) if @ui.respond_to?(:tool_finished)
        payload = {
          name: name,
          output: truncate_for_event(result&.output.to_s),
          duration_ms: duration_ms,
          error_code: result.respond_to?(:error_code) ? result&.error_code : nil
        }
        # On completion the `output` already carries the subagent's returned
        # summary; tag the subagent name (recovered from the call arguments) so
        # the consumer can render "X answered" and group it with the start.
        if name == "task" && arguments.is_a?(Hash)
          subagent = arguments[:subagent]
          payload[:subagent] = subagent.to_s unless subagent.nil?
        end
        @event_bus&.emit(Interaction::Events::TOOL_FINISHED, **payload)
      end

      # Extracts the { subagent:, prompt: } boundary tag from a `task` call's
      # arguments. Nil-tolerant so a malformed call still emits the event.
      def subagent_tag(arguments)
        return {} unless arguments.is_a?(Hash)

        subagent = arguments[:subagent]
        prompt   = arguments[:prompt]
        tag = {}
        tag[:subagent] = subagent.to_s unless subagent.nil?
        tag[:prompt]   = truncate_for_event(prompt.to_s) unless prompt.nil?
        tag
      end

      def sanitize_arguments_for_event(arguments)
        return arguments unless arguments.is_a?(Hash)

        arguments.each_with_object({}) do |(key, value), memo|
          masked = Util::SecretsMask.mask_value(value, key: key)
          memo[key.to_s] = truncate_for_event(masked.to_s)
        end
      rescue StandardError => e
        # Never block the run because of a serialisation hiccup — drop the
        # arguments rather than crash the tool emission path. Log it so a coding
        # bug here doesn't silently blank every tool event's arguments.
        Rubino.logger&.warn(event: "tool_executor.sanitize_arguments_failed",
                            error: e.message, error_class: e.class.name)
        nil
      end

      def truncate_for_event(text)
        return text if text.nil? || text.bytesize <= EVENT_PREVIEW_MAX

        head = text.byteslice(0, EVENT_PREVIEW_MAX).to_s.force_encoding(text.encoding).scrub("")
        "#{head}\n…[truncated at #{EVENT_PREVIEW_MAX} bytes]"
      end

      # ARTIFACT_CREATED is what SSE consumers (e.g. the web UI) latch onto to
      # render a download card for tools like attach_file. Emit it here so the
      # streaming path (ToolBridge → ToolExecutor, never lands in Loop's
      # execute_tool_calls) propagates the artifact too.
      def emit_artifact(result)
        @event_bus&.emit(Interaction::Events::ARTIFACT_CREATED, **result.artifact)
      end

      def record_denied(name:, call_id:, arguments:, result:, reason:)
        record_audit(
          name: name,
          call_id: call_id,
          arguments: arguments,
          result: result,
          status: "denied",
          error: reason
        )
      rescue StandardError => e
        # Don't fail the user's request just because the audit write failed —
        # but log it, so a silently dropped denial-audit row is traceable.
        Rubino.logger&.warn(event: "tool_executor.record_denied_failed",
                            error: e.message, error_class: e.class.name)
      end

      # Stamps the executor's session id onto the Result (built deep in the tool
      # pipeline with no session context) before the audit write, so the
      # NOT-NULL session_id FK on tool_calls is satisfied (#262). Single
      # chokepoint for every record call — success, failure, and denial.
      def record_audit(name:, call_id:, arguments:, result:, status:, error: nil)
        result.session_id = @session_id if result.respond_to?(:session_id=)
        @tool_call_repository.record(name: name, call_id: call_id, arguments: arguments,
                                     result: result, status: status, error: error)
      end

      # The reason behind the policy's :deny, when the policy exposes one
      # (test doubles may not). nil falls back to the generic policy message.
      def policy_deny_reason
        return :policy unless @approval_policy.respond_to?(:last_deny_reason)

        @approval_policy.last_deny_reason || :policy
      end

      # The single-line "blocked" notice surfaced to stderr (via @ui.warning)
      # when a tool needs approval but there is no interactive session (#260).
      # Names the tool and the actionable escape hatches so a scripted run shows
      # WHY nothing happened instead of failing silently.
      def approval_block_message(tool, arguments)
        lines = UI::CallSummary.render(tool, arguments, width: 0, context: :approval)
        summary = lines.first.to_s.strip
        suffix = summary.empty? ? "" : " (#{summary})"
        "blocked: #{tool.name}#{suffix} needs approval but no interactive session " \
          "(use --yolo to allow, or allowlist it)"
      end

      # Hot retry on escalation denial (Codex-style): when the first shell attempt
      # hit a write-jail EACCES, ask the user for escalation approval and re-run
      # unsandboxed — zero extra model round-trips. Returns the escalated Tools::Result
      # on success, nil when the denial wasn't from the jail or escalation is
      # unavailable/refused. Only fires for foreground shell commands with the jail
      # proven enforcing and the escape hatch open.
      def try_escalation(result, tool, arguments, call_id)
        return nil unless tool.respond_to?(:rerun_escalated)
        return nil unless result.respond_to?(:output)
        return nil unless Security::Sandbox.enforcing?
        return nil unless Security::Sandbox.escalation_allowed?

        # Real tool arguments arrive with STRING keys (JSON tool-call args), so
        # read both stylings — a symbol-only lookup silently yields nil, which
        # turned `command` into "" (retry ran nothing) and `cwd` into nil.
        args    = arguments.is_a?(Hash) ? arguments : {}
        command = (args[:command] || args["command"]).to_s
        cwd     = args[:cwd] || args["cwd"]
        timeout = (args[:timeout] || args["timeout"] || Tools::ShellTool::DEFAULT_TIMEOUT).to_i

        text = result.output.to_s
        return nil if text.empty?
        return nil unless Security::Sandbox.write_jail_attribution(text, cwd: cwd)

        # The first attempt surfaced a jail denial. Ask the user.
        return nil unless @ui.interactive?

        question = "The sandbox blocked this write. Retry outside the sandbox?"
        approved = @ui.confirm(
          question,
          scope: "escalation:#{call_id}",
          tool: tool.name,
          command: command,
          description: Security::Sandbox.escalation_disclosure
        )
        return nil unless approved

        # Re-run unsandboxed. The tool's rerun_escalated bypasses param
        # validation and goes straight to execute_foreground(escalate:true).
        raw = tool.rerun_escalated(command, cwd, timeout)
        Tools::Result.new(
          name: tool.name,
          call_id: call_id,
          output: raw[:output] || raw["output"],
          status: :success,
          metrics: raw[:metrics] || raw["metrics"],
          error_code: raw[:error_code] || raw["error_code"],
          artifact: raw[:artifact] || raw["artifact"]
        )
      rescue StandardError => e
        Rubino.logger&.warn(event: "tool_executor.escalation_failed",
                            error: e.message, error_class: e.class.name)
        nil
      end

      def request_approval(tool, arguments)
        command = Security::ApprovalPolicy.command_string(tool, arguments)
        _hit, pattern_key, description = Security::DangerousPatterns.detect(command)
        @ui.confirm(
          approval_question(tool, arguments),
          scope: approval_scope(tool, arguments),
          tool: tool.name,
          command: command,
          pattern_key: pattern_key,
          description: description
        )
      end

      # Adds each out-of-workspace write target's directory to the session
      # workspace roots so the impending write clears the tool guard + OS
      # write-jail. Best-effort: a widen failure is logged and left to the tool's
      # own boundary guard (which then refuses), so we never write somewhere the
      # workspace still forbids. No-op unless the policy exposes the widen dirs
      # and returns a non-empty set (out-of-workspace structured write only).
      def widen_workspace_if_needed(tool, arguments)
        return unless @approval_policy.respond_to?(:workspace_widen_dirs)

        @approval_policy.workspace_widen_dirs(tool, arguments).each do |dir|
          Workspace.add(dir)
          Rubino.logger&.info(event: "workspace.widened", dir: dir, tool: tool.name)
          @ui.warning("added #{dir} to the workspace for this session") if @ui.respond_to?(:warning)
        end
      rescue StandardError => e
        Rubino.logger&.warn(event: "tool_executor.widen_failed",
                            error: e.message, error_class: e.class.name)
      end

      # Build a stable string identifier for (tool, arguments) so the
      # UI layer can short-circuit on a prior "session"/"always"
      # decision. Reuses the same command extractor ApprovalPolicy
      # already uses for pattern-rule matching to keep the granularity
      # consistent — approving `shell ls` will NOT auto-approve
      # `shell rm -rf /`.
      def approval_scope(tool, arguments)
        cmd = Security::ApprovalPolicy.command_string(tool, arguments)
        cmd.empty? ? tool.name.to_s : "#{tool.name}:#{cmd}"
      end

      # --yolo / approvals.mode: "skip" bypasses request_approval entirely.
      # Without any visual signal the user can't tell that the model just
      # ran (e.g.) `rm -rf` until it's done. Print a single-line warning for
      # risky tools so silence can't mask the auto-approval. Low-risk tools
      # (read, glob, grep) stay quiet — yolo for those is no different from
      # the normal allow path.
      def notify_yolo_if_applicable(tool, arguments)
        return unless @config.dig("approvals", "mode") == "skip"
        return unless tool.respond_to?(:risky?) && tool.risky?

        hint = UI::CallSummary.render(tool, arguments, width: 60, context: :status)
        @ui.warning("⚡ yolo: #{tool.name} #{hint}")
      end

      # Multi-line aware args formatter for the approval prompt.
      #
      # arguments.inspect on a Hash with newline values (shell scripts, file
      # contents) collapses everything into one giant line, which the terminal
      # then truncates at the right edge. The user sees "command=\"ls -la"
      # and approves — without ever seeing the trailing `; rm -rf` that the
      # model actually sent. Lay each key out on its own line; clip long
      # values explicitly; tag dropped lines so silence can't mask intent.
      def approval_question(tool, arguments)
        question = with_mcp_note(tool, build_approval_question(tool, arguments))
        question = with_escalation_note(question)
        with_workspace_note(tool, arguments, question)
      end

      # Prepends the out-of-workspace disclosure when the policy routed THIS write
      # to the widen prompt (last_ask_reason == :outside_workspace): the human
      # sees the target is OUTSIDE the current workspace and that approving adds
      # its directory to the session, so "approve" is an informed widen — not a
      # blind edit that looks in-project. Any other :ask (risk / secret / shell)
      # returns the question unchanged.
      def with_workspace_note(tool, arguments, question)
        return question unless @approval_policy.respond_to?(:last_ask_reason)
        return question unless @approval_policy.last_ask_reason == :outside_workspace

        dirs = @approval_policy.workspace_widen_dirs(tool, arguments)
        return question if dirs.empty?

        "#{question}\n   ↳ OUTSIDE the workspace (#{Workspace.roots.join(", ")}) — " \
          "approving adds #{dirs.join(", ")} for this session"
      end

      # Appends the out-of-jail disclosure when the policy routed THIS call to the
      # escalation prompt (last_ask_reason == :escalation). The wording is
      # mode-aware (full vs protect-home, and the Landlock degrade) and lives in
      # Sandbox#escalation_disclosure so the card can't drift from what the
      # launcher actually does. Any other :ask is unchanged.
      def with_escalation_note(question)
        return question unless @approval_policy.respond_to?(:last_ask_reason)
        return question unless @approval_policy.last_ask_reason == :escalation

        "#{question}\n   ⚠ #{Security::Sandbox.escalation_disclosure}"
      end

      # Appends the external-code disclosure line ONLY for MCP tools, so the human
      # authorising the call knows it runs third-party code on an MCP server
      # (#582). Built-ins return the question unchanged. The line sits under the
      # ⚠ header the CLI prints, on its own indented row.
      def with_mcp_note(tool, question)
        return question unless tool.respond_to?(:mcp?) && tool.mcp?

        "#{question}\n   runs external code on MCP server '#{tool.mcp_server}'"
      end

      # The DISPLAY label for the approval header — an MCP tool reads
      # `echo (mcp:chaos)`, a built-in its bare name. The model-facing tool.name
      # is unaffected (#582).
      def approval_label(tool)
        tool.respond_to?(:display_name) ? tool.display_name : tool.name
      end

      def build_approval_question(tool, arguments)
        label = approval_label(tool)
        pairs = Array(arguments)
        # ONE header verb across every approval card (#558): always
        # "<tool> wants to run" — with the call laid out after a colon when there
        # are args, and as a bare sentence when there are none. The old code mixed
        # "<tool> wants to run" (no-arg) with "<tool> wants:" (with-arg), so the
        # header read inconsistently and the dangling colon looked broken (#109).
        # No arguments (e.g. a bare no-arg tool call) ⇒ no colon: a header followed
        # by nothing reads as a truncated/broken card.
        return "#{label} wants to run" if pairs.empty?

        # Delegate to the tool's own presentation layer for custom previews
        # (edit → diff or per-edit blocks, etc.). Fall back to the
        # generic key-value formatter when the tool doesn't provide one.
        if (preview = tool.presentation.preview_arguments(label, arguments))
          return preview
        end

        # The common case — ONE single-line argument (a shell command, a
        # file path) — inlines onto the header: `shell wants to run: touch hello.txt`
        # (P7). Multi-line calls keep the per-key layout below.
        # No length cap — the user must see the full command/path when approving.
        # Route the VALUE through CallSummary so the summary DSL drives the label
        # (workspace-relative paths, tool-specific formatting) and
        # mask+sanitize is applied consistently.
        if pairs.size == 1
          text = UI::CallSummary.label_for(tool, arguments)
          if text.nil?
            key, value = pairs.first
            text = UI::CallSummary.mask_and_sanitize(value, key: key)
          end
          if text && !text.include?("\n")
            header = "#{label} wants to run: #{text}"
            # Wrap to fit inside the real terminal width, budgeting for the
            # "⚠ " prefix the CLI adds to the first line of every approval card.
            wrap = [approval_wrap_width - 2, 1].max
            if header.length > wrap
              return UI::CallSummary.wrap_line(header, wrap).join("\n")
            end
            return header
          end
        end

        lines = ["#{label} wants to run:"]
        pairs.each { |key, value| lines.concat(format_arg_pair(key, value)) }
        lines.join("\n")
      end

      # Formats a single key-value pair for the multi-arg approval layout.
      # Routes EVERY value through CallSummary.mask_and_sanitize (the SAME
      # mask+sanitize primitive CallSummary uses) — a single chokepoint so
      # terminal escapes are defanged (CWE-150) and secrets are masked
      # consistently. Multi-line values: first 5 lines + explicit
      # "+N more line(s)" marker. Single-line values: full fidelity, wrapped
      # at terminal width instead of a hardcoded constant.
      def format_arg_pair(key, value)
        text = UI::CallSummary.mask_and_sanitize(value, key: key)
        if text.include?("\n")
          body = text.lines.map(&:rstrip)
          head = body.first(5)
          tail = body.size > 5 ? ["  [… #{body.size - 5} more line(s)]"] : []
          ["  #{key}:", *head.map { |l| "    #{l}" }, *tail]
        else
          # Full fidelity — no char cap, the user must see what they approve.
          # Wrap long single-line values so they don't run off the terminal edge.
          UI::CallSummary.wrap_line("  #{key}: #{text}", approval_wrap_width)
        end
      end

      # The column budget for wrapping approval-card lines. Grabs the real
      # terminal width from the UI when available; falls back to 80 for
      # non-CLI adapters (Null, API) and headless runs.
      def approval_wrap_width
        if @ui.respond_to?(:terminal_cols)
          @ui.terminal_cols
        else
          80
        end
      end

      # Routes the model-facing tool output through the single ContentRouter
      # seam and, when a strategy COMPRESSED it, spills the full original to
      # tool-results/<call_id>.txt and appends a pointer so the model can read it
      # back with the normal `read` tool (the same recovery path truncation
      # already uses). Returns [text, metrics] — unchanged when nothing applied,
      # so a passthrough output is byte-identical. Never raises: the router
      # itself swallows strategy errors into a passthrough result.
      def maybe_compress(text, metrics:, name:, arguments:, compress_hint:, call_id:)
        return [text, metrics] if text.nil? || text.empty?

        compress = compress_requested?(arguments)
        router = compression_router
        result = router.route(text, tool_name: name, compress_hint: compress_hint, compress: compress)
        return [text, metrics] unless result.applied?

        spill_path = spill_full_output(text, call_id)
        # Read drill-in telemetry: record the elided ranges so a later targeted
        # read inside one is logged as a drill-in (the read tool's skeleton
        # behavior, now driven from this seam rather than inside the tool).
        note_code_skeleton(compress_hint, router) if result.content_type == :code

        emit_compression_event(name, result, text)
        # Pointer references the call_id-based id, NOT a path: recovery is only
        # via retrieve_output. The id is the spill file's basename (already the
        # sanitized call_id), so it round-trips; nil when the spill failed.
        spill_id = spill_path ? File.basename(spill_path, ".txt") : nil
        compressed = append_recovery_pointer(result.text, text, spill_id, result.content_type)
        [compressed, compression_metrics(result, metrics)]
      rescue StandardError => e
        Rubino.logger&.warn(event: "compression.seam_failed", tool: name,
                            error: e.message, error_class: e.class.name)
        [text, metrics]
      end

      def compression_router
        @compression_router ||= Compression::ContentRouter.new(@config)
      end

      # The per-call opt-out: `compress: false` on read/shell forces passthrough.
      # Defaults to true (advertised only when the feature is enabled).
      def compress_requested?(arguments)
        return true unless arguments.is_a?(Hash)

        value = arguments[:compress]
        value != false
      end

      # For a :code skeleton, register the elided ranges on the read tracker so a
      # later targeted read into an elided body is flagged as a drill-in (the
      # "did the skeleton hide what was needed" signal). Keyed on the EXPANDED
      # path the read tool stamped into the compress_hint.
      def note_code_skeleton(compress_hint, router)
        return unless @read_tracker && compress_hint.is_a?(Hash)

        expanded = compress_hint[:tracker_path] || compress_hint["tracker_path"]
        return unless expanded

        @read_tracker.note_skeleton(expanded, router.last_elided_ranges)
      rescue StandardError
        nil # telemetry only — never break the tool call
      end

      # The reversibility pointer: a single line stating how much was hidden, that
      # failures/summary (logs) or large bodies (code) are kept and normally
      # sufficient, and — passively, only "if a hidden line is specifically
      # needed" — the ID to recover the original verbatim via the retrieve_output
      # tool. Deliberately NO filesystem path: the headroom-style recovery is an
      # id behind a dedicated tool, so a small model can't `sed`/`grep`/`cat` a
      # printed spill path and re-inflate the very output compression shrank. The
      # conditional framing avoids baiting a reflexive drill-in. Falls back to a
      # path-less, id-less note if the spill failed.
      def append_recovery_pointer(compressed, original, spill_id, content_type)
        orig_lines = original.count("\n") + (original.end_with?("\n") ? 0 : 1)
        kept_lines = compressed.count("\n") + (compressed.end_with?("\n") ? 0 : 1)
        hidden = [orig_lines - kept_lines, 0].max
        kept_note = COMPRESSION_KEPT_NOTES[content_type] || "failures + summary kept"
        recover = spill_id ? "retrieve_output id=#{spill_id} only if a hidden line is specifically needed" : "full output unavailable (spill failed)" # rubocop:disable Layout/LineLength
        "#{compressed}\n[… #{hidden} lower-signal line(s) hidden by output compression — #{kept_note}, normally sufficient; #{recover}.]" # rubocop:disable Layout/LineLength
      end

      def compression_metrics(result, existing)
        tag = result.content_type == :code ? "skeleton" : "compressed"
        note = "⚡ #{tag} −#{result.saved_tokens_est} tok"
        existing && !existing.to_s.empty? ? "#{existing} · #{note}" : note
      end

      # Unified compression telemetry: one event for every applied compression,
      # tagged with the content_type so the log distinguishes log vs code.
      def emit_compression_event(name, result, original)
        orig_bytes = original.bytesize
        comp_bytes = result.text.bytesize
        ratio = orig_bytes.zero? ? 0.0 : (orig_bytes - comp_bytes).fdiv(orig_bytes)
        Rubino.logger&.info(event: "compression.applied", tool: name,
                            content_type: result.content_type, strategy: result.strategy,
                            ratio: ratio.round(3), original_bytes: orig_bytes,
                            compressed_bytes: comp_bytes, saved_tokens_est: result.saved_tokens_est)
      rescue StandardError
        nil
      end

      # Persists the complete (pre-truncation) output to a per-call file under
      # the rubino home so the model can read back whatever the inline
      # head+tail elided (the spill seam Util::Output.truncate calls back into
      # on overflow — Util keeps the pure shaping, the executor keeps the IO).
      # Best-effort: a write failure just yields no path and the marker falls
      # back to its grep/head hint. Returns the path or nil.
      # Emits compression.drill_in for a retrieve_output call (the deliberate
      # recovery), carrying the id. Best-effort: telemetry never breaks the call.
      def log_retrieve_drill_in(arguments)
        id = arguments.is_a?(Hash) ? arguments[:id] : nil
        Rubino.logger&.info(event: "compression.drill_in", tool: "retrieve_output", id: id.to_s)
      rescue StandardError
        nil
      end

      def spill_full_output(text, call_id)
        # Sanitized identically to RetrieveOutputTool so the pointer's id (this
        # file's basename) round-trips back to it.
        id = call_id.to_s.gsub(/[^a-zA-Z0-9_.-]/, "_")
        return nil if id.empty?

        dir = File.join(Rubino.home_path, "tool-results")
        FileUtils.mkdir_p(dir)
        path = File.join(dir, "#{id}.txt")
        # Write ATOMICALLY (temp + rename): a plain File.write can be cut MID-
        # WRITE by an Interrupt (Ctrl+C) — which is NOT a StandardError, so the
        # rescue below never catches it — leaving a TRUNCATED recovery file the
        # marker still points the model at, so it reads back a silently partial
        # output. rename(2) on the same filesystem is atomic, so a reader sees
        # either the old file or the complete new one, never a torn one; the temp
        # is cleaned up if the interrupt lands before the rename.
        tmp = "#{path}.#{Process.pid}.#{SecureRandom.hex(4)}.tmp"
        begin
          File.write(tmp, text)
          File.rename(tmp, path)
        rescue Exception # rubocop:disable Lint/RescueException
          FileUtils.rm_f(tmp)
          raise
        end
        path
      rescue StandardError => e
        Rubino.logger&.warn(event: "tool_output.spill_failed", error: e.message)
        nil
      end
    end
  end
end
