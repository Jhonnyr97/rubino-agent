# frozen_string_literal: true

module Rubino
  module Agent
    # Executes tool calls with approval checks and result formatting.
    class ToolExecutor
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
        tool = @registry.find(name)
        raise ToolError, "Unknown tool: #{name}" unless tool

        case @approval_policy.decide(tool, arguments: arguments)
        when :deny
          # A policy denial must NOT read "denied by user" to the model — the
          # policy records why it fired (#last_deny_reason) and the Result
          # maps it to a reason-specific message, so a child agent never
          # blames the human for an automatic deny (#143).
          denied = Tools::Result.denied(name: name, call_id: call_id, reason: policy_deny_reason)
          record_denied(name: name, call_id: call_id, arguments: arguments,
                        result: denied, reason: "policy-denied")
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

        notify_yolo_if_applicable(tool, arguments)
        emit_started(name, arguments)
        started_at = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        result = nil
        begin
          result = run_tool(tool, name: name, arguments: arguments, call_id: call_id)
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
      def finish(name, arguments, call_id, result)
        @on_result&.call(name: name, arguments: arguments, call_id: call_id, result: result)
        result
      rescue StandardError => e
        Rubino.logger&.warn(event: "tool_executor.on_result_failed", error: e.message)
        result
      end

      def run_tool(tool, name:, arguments:, call_id:)
        tool.cancel_token = @cancel_token if tool.respond_to?(:cancel_token=)
        tool.read_tracker = @read_tracker if tool.respond_to?(:read_tracker=)
        streamed = false
        last_progress_at = nil
        if tool.respond_to?(:stream_chunk=) && (@ui.respond_to?(:tool_chunk) || @event_bus)
          tool.stream_chunk = lambda do |chunk|
            streamed = true
            @ui.tool_chunk(name, chunk) if @ui.respond_to?(:tool_chunk)
            # Mirror the chunk onto the bus so the API/SSE stream isn't silent
            # during a long tool call: the Recorder maps TOOL_PROGRESS to a
            # `tool.progress` event, which resets the idle watchdog. Without
            # this a busy tool (summarize_file: ~30 sequential aux-LLM calls,
            # no run-events) is killed at the 300s idle timeout. Throttled so a
            # chatty tool (shell streaming thousands of stdout lines) doesn't
            # write a DB row + SSE frame per line — one heartbeat per interval
            # is enough to keep the watchdog satisfied.
            last_progress_at = emit_tool_progress(name, chunk, last_progress_at) if @event_bus
          end
        end
        raw = tool.call(arguments)
        # Tools can return either a String (plain output) or a Hash carrying
        # {output:, metrics:, body:, body_kind:}. The Hash form lets a tool emit
        #   - a `metrics` one-liner for the done header ("42 lines · 0.1s")
        #   - a `body` block (diff, preview) printed inside the tool box
        #   - a `body_kind` (:diff | :plain) selecting the CLI coloring for body
        # without having to reverse-engineer them from the formatted output.
        if raw.is_a?(Hash)
          text       = raw[:output]     || raw["output"]
          metrics    = raw[:metrics]    || raw["metrics"]
          body       = raw[:body]       || raw["body"]
          body_kind  = raw[:body_kind]  || raw["body_kind"] || :plain
          error_code = raw[:error_code] || raw["error_code"]
          artifact   = raw[:artifact]   || raw["artifact"]
        else
          text = raw
          metrics = nil
          body = nil
          body_kind = :plain
          error_code = nil
          artifact = nil
        end
        # Skip the body block when the tool already streamed its output line by
        # line via #tool_chunk: `body` is the SAME content (e.g. ShellTool's
        # Util::Output.preview of the captured stdout), so rendering it again
        # would duplicate every line in the timeline. Tools that don't stream
        # (read, grep, edit, glob, github) still render their body here.
        @ui.tool_body(body, kind: body_kind.to_sym) if body && !body.to_s.empty? && !streamed
        result = Tools::Result.success(
          name: name,
          call_id: call_id,
          output: Util::Output.truncate(text, max_bytes: @config.tool_output_max_bytes,
                                              max_lines: @config.tool_output_max_lines,
                                              spill: ->(full) { spill_full_output(full, call_id) }),
          metrics: metrics,
          error_code: error_code&.to_sym,
          artifact: artifact
        )
        record_audit(name: name, call_id: call_id, arguments: arguments,
                     result: result, status: "completed")
        result
      rescue StandardError => e
        result = Tools::Result.error(name: name, call_id: call_id, error: e.message)
        record_audit(name: name, call_id: call_id, arguments: arguments,
                     result: result, status: "failed", error: e.message)
        result
      ensure
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

      def emit_started(name, arguments)
        sanitized = sanitize_arguments_for_event(arguments)
        @ui.tool_started(name, arguments: arguments) if @ui.respond_to?(:tool_started)
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
          subagent = arguments["subagent"] || arguments[:subagent]
          payload[:subagent] = subagent.to_s unless subagent.nil?
        end
        @event_bus&.emit(Interaction::Events::TOOL_FINISHED, **payload)
      end

      # Extracts the { subagent:, prompt: } boundary tag from a `task` call's
      # arguments. Nil-tolerant so a malformed call still emits the event.
      def subagent_tag(arguments)
        return {} unless arguments.is_a?(Hash)

        subagent = arguments["subagent"] || arguments[:subagent]
        prompt   = arguments["prompt"]   || arguments[:prompt]
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
      rescue StandardError
        # Never block the run because of a serialisation hiccup — drop the
        # arguments rather than crash the tool emission path.
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
      rescue StandardError
        # Don't fail the user's request just because the audit write failed.
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
        cmd = Security::ApprovalPolicy.command_string(tool, arguments).to_s
        cmd = cmd.lines.first.to_s.rstrip
        cmd = "#{cmd[0, 57]}…" if cmd.length > 60
        suffix = cmd.empty? ? "" : " (#{cmd})"
        "blocked: #{tool.name}#{suffix} needs approval but no interactive session " \
          "(use --yolo to allow, or allowlist it)"
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

        preview = if arguments.is_a?(Hash)
                    arguments.map { |k, v| "#{k}=#{summarize_yolo_value(v, key: k)}" }.join(" ")
                  else
                    Util::SecretsMask.mask_inline(arguments.to_s)
                  end
        @ui.warning("⚡ yolo: #{tool.name} #{preview}")
      end

      def summarize_yolo_value(value, key: nil)
        masked = Util::SecretsMask.mask_value(value, key: key).to_s
        masked = masked.lines.first.to_s.rstrip if masked.include?("\n")
        masked.length > 60 ? "#{masked[0, 57]}…" : masked
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
        pairs = Array(arguments)
        # No arguments (e.g. a bare run_tests run) ⇒ no dangling "wants:" — a
        # header followed by nothing reads as a truncated/broken card (#109).
        return "#{tool.name} wants to run" if pairs.empty?

        # The common case — ONE short single-line argument (a shell command, a
        # file path) — inlines onto the header: `shell wants:  touch hello.txt`
        # (P7). Multi-arg / multi-line calls keep the per-key layout below.
        if pairs.size == 1
          key, value = pairs.first
          text = Util::SecretsMask.mask_value(value, key: key).to_s
          return "#{tool.name} wants:  #{text}" if !text.include?("\n") && text.length <= 120
        end

        lines = ["#{tool.name} wants:"]
        pairs.each { |key, value| lines.concat(format_arg_pair(key, value)) }
        lines.join("\n")
      end

      def format_arg_pair(key, value)
        # Mask credentials before any rendering: the approval prompt is the
        # one place a real secret value could land in the user's scrollback
        # if the model passed it through unwrapped.
        text = Util::SecretsMask.mask_value(value, key: key).to_s
        if text.include?("\n")
          body = text.lines
          head = body.first(5).map(&:rstrip)
          tail = body.size > 5 ? ["  [… #{body.size - 5} more line(s)]"] : []
          ["  #{key}:", *head.map { |l| "    #{l}" }, *tail]
        elsif text.length > 120
          ["  #{key}: #{text[0, 117]}…"]
        else
          ["  #{key}: #{text}"]
        end
      end

      # Persists the complete (pre-truncation) output to a per-call file under
      # the rubino home so the model can read back whatever the inline
      # head+tail elided (the spill seam Util::Output.truncate calls back into
      # on overflow — Util keeps the pure shaping, the executor keeps the IO).
      # Best-effort: a write failure just yields no path and the marker falls
      # back to its grep/head hint. Returns the path or nil.
      def spill_full_output(text, call_id)
        id = call_id.to_s.gsub(/[^a-zA-Z0-9_.-]/, "_")
        return nil if id.empty?

        dir = File.join(Rubino.home_path, "tool-results")
        FileUtils.mkdir_p(dir)
        path = File.join(dir, "#{id}.txt")
        File.write(path, text)
        path
      rescue StandardError => e
        Rubino.logger&.warn(event: "tool_output.spill_failed", error: e.message)
        nil
      end
    end
  end
end
