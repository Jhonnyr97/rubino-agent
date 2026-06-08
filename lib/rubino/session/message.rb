# frozen_string_literal: true

require "securerandom"
require "json"

module Rubino
  module Session
    # Handles message persistence within a session.
    # Messages include user input, assistant responses, tool calls and results.
    class Message
      VALID_ROLES = %w[system user assistant tool].freeze

      attr_reader :id, :session_id, :role, :content, :tool_name,
                  :tool_call_id, :token_count, :metadata, :created_at

      def initialize(attrs = {})
        @id = attrs[:id] || SecureRandom.uuid
        @session_id = attrs[:session_id]
        @role = attrs[:role]
        @content = attrs[:content]
        @tool_name = attrs[:tool_name]
        @tool_call_id = attrs[:tool_call_id]
        @token_count = attrs[:token_count] || 0
        @metadata = attrs[:metadata] || {}
        @created_at = attrs[:created_at] || Time.now.utc.iso8601
      end

      # Validates the message attributes
      def valid?
        VALID_ROLES.include?(@role) && @session_id
      end

      # Returns a hash suitable for database insertion
      def to_row
        {
          id: @id,
          session_id: @session_id,
          role: @role,
          content: @content,
          tool_name: @tool_name,
          tool_call_id: @tool_call_id,
          token_count: @token_count,
          metadata_json: @metadata.empty? ? nil : JSON.generate(@metadata),
          created_at: @created_at
        }
      end

      # Returns a hash for LLM context building
      def to_context
        msg = { role: @role, content: @content }
        msg[:tool_call_id] = @tool_call_id if @tool_call_id
        msg[:name] = @tool_name if @tool_name
        # Surface assistant tool_calls (persisted as metadata) so the adapter
        # can rebuild the toolUse block expected by strict providers on resume.
        msg[:tool_calls] = @metadata[:tool_calls] if @metadata.is_a?(Hash) && @metadata[:tool_calls]
        msg
      end
    end
  end
end
