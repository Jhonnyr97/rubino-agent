# frozen_string_literal: true

module Rubino
  # Plugin system with event hooks.
  # Plugins can subscribe to events and modify behavior.
  #
  # Usage:
  #   Rubino.plugin do
  #     on(:tool_execute_before) do |context|
  #       # Modify or inspect tool call before execution
  #     end
  #
  #     on(:tool_execute_after) do |context|
  #       # React to tool results
  #     end
  #
  #     on(:session_start) do |context|
  #       # Do something when a session starts
  #     end
  #   end
  #
  module Plugins
    # All supported hook points (30+)
    HOOKS = %i[
      tool_execute_before
      tool_execute_after
      tool_approval_before
      tool_approval_after
      tool_result_transform

      shell_env
      shell_execute_before
      shell_execute_after

      file_read_before
      file_read_after
      file_write_before
      file_write_after

      compaction_before
      compaction_after
      compaction_context_inject

      session_start
      session_end
      session_fork
      session_persist

      message_before
      message_after
      message_stream_chunk

      memory_extract
      memory_save_before
      memory_retrieve_after

      job_before
      job_after
      job_failed

      model_call_before
      model_call_after
      model_response_transform

      prompt_assemble_before
      prompt_assemble_after

      agent_switch
      agent_route

      config_reload
      startup
      shutdown
    ].freeze

    class << self
      def registry
        @registry ||= Registry.new
      end

      def reset!
        @registry = nil
      end
    end
  end
end
