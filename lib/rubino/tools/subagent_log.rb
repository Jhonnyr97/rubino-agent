# frozen_string_literal: true

require "json"
require "securerandom"
require "fileutils"

module Rubino
  module Tools
    # Per-subagent JSONL log file — post-mortem forensics when a subagent dies
    # unexpectedly. Mirrors Claude Code's task log format: one JSON object per
    # line, append-only, sync-flushed so data survives a process crash.
    #
    #   log = SubagentLog.new(sa_id: "sa_abc123", session_id: "sess_xyz")
    #   log.write_event("subagent_started", subagent: "explore", prompt: "...")
    #   log.write_event("assistant", content: [...], usage: {...})
    #   log.write_event("tool_result", tool_use_id: "...", output: "...")
    #   log.write_event("result", status: "completed", summary: "...")
    #   log.close
    #
    # File lives at: <rubino_home>/sessions/<session_id>/tasks/<sa_id>.jsonl
    class SubagentLog
      def initialize(sa_id:, session_id:)
        @sa_id = sa_id
        @session_id = session_id
        @path = build_path
        @io = open_file
        @closed = false
      end

      attr_reader :path

      # Writes one JSONL event, flushed immediately for crash safety.
      def write_event(type, **fields)
        return if @closed || @io.nil?

        event = {
          type: type,
          uuid: SecureRandom.uuid,
          timestamp: Time.now.utc.iso8601,
          sessionId: @session_id,
          taskId: @sa_id,
          **fields
        }
        line = "#{JSON.generate(event)}\n"
        @io.write(line)
      rescue IOError, Errno::EBADF
        @closed = true
        nil
      end

      def close
        return if @closed || @io.nil?

        @closed = true
        @io.close
      rescue IOError, Errno::EBADF
        nil
      end

      # Wraps a real Session::Store, teeing every #create call to the log file.
      # Delegates all other methods unchanged.
      class TeeStore
        def initialize(real_store, log)
          @real = real_store
          @log = log
        end

        def create(session_id:, role:, content:, **attrs)
          @real.create(session_id: session_id, role: role, content: content, **attrs)
          tee_to_log(role: role, content: content, **attrs)
        end

        # Delegate everything else to the real store
        def method_missing(method, ...)
          if @real.respond_to?(method)
            @real.public_send(method, ...)
          else
            super
          end
        end

        def respond_to_missing?(method, include_private = false)
          @real.respond_to?(method) || super
        end

        private

        def tee_to_log(role:, content:, **attrs)
          case role
          when "user"
            @log.write_event("user", message: { role: "user", content: content.to_s })
          when "assistant"
            metadata = attrs[:metadata] || {}
            tool_calls = metadata[:tool_calls]
            blocks = build_assistant_blocks(content, tool_calls)
            @log.write_event("assistant",
                             message: {
                               content: blocks,
                               usage: token_usage(metadata)
                             })
          when "tool"
            @log.write_event("tool_result",
                             tool_use_id: attrs[:tool_call_id],
                             tool_name: attrs[:tool_name],
                             output: content.to_s)
          end
        end

        def build_assistant_blocks(content, tool_calls)
          blocks = []
          blocks << { type: "text", text: content.to_s } unless content.to_s.empty?

          if tool_calls.is_a?(Array)
            tool_calls.each do |tc|
              blocks << {
                type: "tool_use",
                id: tc[:id] || tc["id"],
                name: tc[:name] || tc["name"] || tc[:function]&.dig(:name) || tc["function"]&.dig("name"),
                input: tc[:input] || tc["input"] || tc[:function]&.dig(:arguments) || {}
              }
            end
          end
          blocks
        end

        def token_usage(attrs)
          return nil unless attrs[:token_count]

          {
            total_tokens: attrs[:token_count]
          }
        end
      end

      private

      def build_path
        # Log files live under the workspace so the OS write-jail allows them
        # (~/.rubino is protected — same reason shell logs use the workspace).
        root = begin
          Rubino::Workspace.primary_root
        rescue StandardError
          File.expand_path("~/")
        end
        dir = File.join(root, ".rubino", "sessions", @session_id, "tasks")
        FileUtils.mkdir_p(dir)
        File.join(dir, "#{@sa_id}.jsonl")
      end

      def open_file
        file = File.open(@path, "w") # rubocop:disable Style/FileOpen -- sync-flushed for crash safety
        file.sync = true
        file
      rescue StandardError => e
        Rubino.logger&.warn(msg: "Failed to open subagent log file: #{e.message}")
        nil
      end
    end
  end
end
