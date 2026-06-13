# frozen_string_literal: true

module Rubino
  module Tools
    # Encapsulates the result of a tool execution.
    class Result
      attr_reader :name, :call_id, :output, :status, :error,
                  :metrics, :error_code, :artifact
      # Stamped by the ToolExecutor just before the audit write (the Result is
      # built deep in the tool pipeline, which has no session context). nil for
      # results created outside a session (one-shot / test path).
      attr_accessor :session_id

      # `error_code` is an optional Symbol surface for callers (UI badges,
      # automation, future contract tests) that want to branch on the
      # failure mode without parsing the human-facing error string. Today
      # the canonical signal is still the output text — the symbol is a
      # belt-and-suspenders next to it, not a replacement.
      #
      # `artifact` is an optional Hash carrying { path:, filename:,
      # content_type:, byte_size: } when a tool produced a downloadable
      # user-facing file. The agent loop reads this and emits an
      # ARTIFACT_CREATED bus event so SSE consumers (the web UI, the CLI)
      # can offer a download.
      def initialize(name:, call_id:, output:, status:, error: nil,
                     metrics: nil, error_code: nil, artifact: nil)
        @name = name
        @call_id = call_id
        @output = output
        @status = status
        @error = error
        @metrics = metrics
        @error_code = error_code
        @artifact = artifact
        @session_id = nil
      end

      def success?
        @status == :success
      end

      def failed?
        @status == :error
      end

      def denied?
        @status == :denied
      end

      # True when this result represents a failure for DISPLAY purposes, even
      # when the tool didn't raise. Many tools (read, edit, …) report a soft
      # failure by RETURNING an "Error: …" string (status stays :success) or by
      # setting an error_code, instead of raising. The CLI used to render those
      # as a green "✓ done" because it only checked #success?. This is the
      # single predicate the UI uses so an errored tool shows "✗" regardless of
      # which failure convention the tool used.
      def errorish?
        return true unless success?
        return true unless @error_code.nil?

        @output.to_s.start_with?("Error:")
      end

      # Returns a truncated preview for display
      def truncated_preview(max_length: 80)
        text = @output.to_s
        text.length > max_length ? "#{text[0...max_length]}..." : text
      end

      # Substituted when a tool legitimately produces no output (e.g. `touch`).
      # The string survives persistence and load_history, where nil/"" would
      # be dropped and leave a tool_call orphaned — the provider then 400s
      # the next turn for a tool_call with no matching tool_result.
      EMPTY_OUTPUT_PLACEHOLDER = "(no output)"

      # Factory methods
      def self.success(name:, call_id:, output:, metrics: nil, error_code: nil, artifact: nil)
        new(name: name, call_id: call_id, output: normalize_output(output),
            status: :success, metrics: metrics, error_code: error_code, artifact: artifact)
      end

      def self.error(name:, call_id:, error:, error_code: nil)
        msg = error.to_s
        msg = "unknown error" if msg.empty?
        new(name: name, call_id: call_id, output: "Error: #{msg}", status: :error,
            error: error, error_code: error_code)
      end

      # Model-facing text per denial reason (#143). Only a real human decision
      # may read "denied by user" — an automatic denial must name the policy
      # that fired, otherwise a child agent reports (and propagates upward)
      # that "the user denied my tools" when no human ever decided anything.
      DENIED_OUTPUTS = {
        user: "Tool execution denied by user.",
        policy: "Tool execution denied by policy (not by the user).",
        hardline: "Tool execution blocked by policy (hardline safety floor, not by the user): " \
                  "this command is never allowed.",
        permission_rule: "Tool execution blocked by policy (a configured permissions deny rule, " \
                         "not by the user).",
        noninteractive: "Tool execution blocked: this tool needs approval but there is no " \
                        "interactive session to ask (headless/one-shot run). It was NOT run. " \
                        "Re-run with --yolo to auto-approve, or add it to the permissions " \
                        "allowlist.",
        doom_loop: "Tool execution blocked by the doom-loop guard (policy, not by the user): " \
                   "this exact call was already made repeatedly. Change strategy instead of " \
                   "retrying it — e.g. wait for the background-task completion notice instead " \
                   "of polling."
      }.freeze

      def self.denied(name:, call_id:, reason: :user)
        key = DENIED_OUTPUTS.key?(reason) ? reason : :policy
        new(name: name, call_id: call_id, output: DENIED_OUTPUTS[key], status: :denied)
      end

      def self.normalize_output(output)
        text = output.to_s
        text.empty? ? EMPTY_OUTPUT_PLACEHOLDER : text
      end
    end
  end
end
