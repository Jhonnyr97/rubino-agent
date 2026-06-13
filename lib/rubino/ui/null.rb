# frozen_string_literal: true

module Rubino
  module UI
    # Null UI adapter that discards all output.
    # Used in testing and background job execution
    # where no terminal output is needed.
    class Null < Base
      attr_reader :messages

      def initialize
        @messages = []
      end

      def info(message)
        @messages << { level: :info, message: message }
      end

      def success(message)
        @messages << { level: :success, message: message }
      end

      def warning(message)
        @messages << { level: :warning, message: message }
      end

      def error(message)
        @messages << { level: :error, message: message }
      end

      def status(message)
        @messages << { level: :status, message: message }
      end

      def box_open(*pieces, at: nil, color: nil)
        @messages << { level: :box_open, pieces: pieces, at: at, color: color }
      end

      def box_close(*pieces, color: nil)
        @messages << { level: :box_close, pieces: pieces, color: color }
      end

      def body(text)
        @messages << { level: :body, message: text }
      end

      def assistant_text(text)
        @messages << { level: :assistant_text, message: text }
      end

      def note(text)
        @messages << { level: :note, message: text }
      end

      def probe_aside(answer)
        @messages << { level: :probe_aside, message: answer.to_s }
      end

      def branch_confirmation(new_id:, parent_id:, title:, included_probe:)
        @messages << {
          level: :branch_confirmation,
          message: { new_id: new_id, parent_id: parent_id, title: title,
                     included_probe: included_probe }
        }
      end

      def stream(chunk)
        # Every adapter yields the common chunk contract:
        #   { type: :content | :thinking, text: String, message_id: Integer }
        text = chunk[:text].to_s
        type = chunk[:type] || :content
        @messages << { level: :stream, message: text, stream_type: type }
      end

      def stream_end
        @messages << { level: :stream_end, message: "" }
      end

      def replay_user_input(text, at: nil)
        @messages << { level: :replay_user_input, message: text, at: at }
      end

      def thinking_started
        @messages << { level: :thinking_started, message: "" }
      end

      def thinking_finished
        @messages << { level: :thinking_finished, message: "" }
      end

      def table(headers:, rows:)
        @messages << { level: :table, message: { headers: headers, rows: rows } }
      end

      def ask(_prompt)
        nil
      end

      # No interactive selection off a real terminal; callers fall back to a
      # non-interactive path (e.g. the static /sessions table + shortcut).
      def select(_prompt, _choices)
        nil
      end

      # Headless: there is no human to ask, so FAIL CLOSED (#260). The Null
      # adapter drives the one-shot / scripted `rubino prompt` / `-q` path; it
      # used to return true here, silently auto-approving every write and every
      # non-allowlisted shell command — a prompt-injection→RCE foot-gun (the
      # Gemini-CLI / Dec-2025 auto-approve-writes pattern). ToolExecutor now
      # checks #interactive? BEFORE ever reaching #confirm, so this is the
      # belt-and-suspenders floor: declining is the only safe default off a TTY.
      # `scope:` is part of the shared UI contract (ToolExecutor always passes
      # it); the Null adapter ignores it.
      def confirm(_question, scope: nil, **_context)
        false
      end

      # No interactive session — no terminal, no approval gate. Tells
      # ToolExecutor to fail closed on any tool that needs approval (#260).
      def interactive?
        false
      end

      # Latched by ToolExecutor when a tool is blocked for approval in this
      # headless run (#260). The one-shot CLI reads #approval_blocked? after the
      # run to exit NON-ZERO so CI/automation fails loudly.
      def tool_blocked(message)
        @approval_blocked = true
        @messages << { level: :tool_blocked, message: message }
      end

      def approval_blocked?
        @approval_blocked == true
      end

      # The single-line block notices captured during a headless run, in order,
      # so the one-shot CLI can echo them to stderr before exiting non-zero
      # (#260) — UI::Null otherwise swallows every #warning into @messages.
      def blocked_messages
        @messages.select { |m| m[:level] == :tool_blocked }.map { |m| m[:message] }
      end

      # Destructive confirm (#218): no human to ask, so fail closed (decline)
      # — never destroy on the non-interactive Null adapter.
      def confirm_destructive(_question)
        false
      end

      def tool_started(name, arguments: nil, at: nil)
        @messages << { level: :tool_started, message: name, arguments: arguments, at: at }
      end

      def tool_finished(name, result: nil)
        @messages << { level: :tool_finished, message: name }
      end

      def tool_body(text, kind: :plain)
        @messages << { level: :tool_body, message: text, kind: kind }
      end

      def tool_chunk(name, chunk)
        @messages << { level: :tool_chunk, name: name, chunk: chunk }
      end

      def compression_started(at: nil)
        @messages << { level: :compression_started, message: "", at: at }
      end

      def compression_finished(metadata, at: nil)
        @messages << { level: :compression_finished, message: metadata, at: at }
      end

      def job_enqueued(type)
        @messages << { level: :job_enqueued, message: type }
      end

      def job_started(type)
        @messages << { level: :job_started, message: type }
      end

      def job_finished(type)
        @messages << { level: :job_finished, message: type }
      end

      def separator
        @messages << { level: :separator, message: "" }
      end

      def blank_line
        @messages << { level: :blank_line, message: "" }
      end

      def mode_changed(name, previous: nil)
        @messages << { level: :mode_changed, message: name, previous: previous }
      end

      def reasoning_status(mode)
        @messages << { level: :reasoning_status, message: mode }
      end

      def reasoning_changed(mode, previous: nil)
        @messages << { level: :reasoning_changed, message: mode, previous: previous }
      end

      def think_status(effort)
        @messages << { level: :think_status, message: effort }
      end

      def think_changed(effort, previous: nil)
        @messages << { level: :think_changed, message: effort, previous: previous }
      end

      def queued(text)
        @messages << { level: :queued, message: text }
      end

      def input_injected(text)
        @messages << { level: :input_injected, message: text }
      end

      # Resets captured messages (useful between test cases)
      def reset!
        @messages = []
      end
    end
  end
end
