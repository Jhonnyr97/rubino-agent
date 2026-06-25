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
      #
      # Free-text columns are run through Util::Output.scrub_utf8 at this PERSIST
      # seam (#498): a NUL byte is valid UTF-8 (so it survives String#scrub) yet
      # terminates SQLite's C string mid-literal, surfacing a raw
      # `SQLite3::SQLException: unrecognized token` even through bound params.
      # Scrubbing here (the single message-write chokepoint) keeps every prompt
      # storable no matter what control bytes a paste/upstream model emitted,
      # and is idempotent on already-clean input.
      def to_row
        {
          id: @id,
          session_id: @session_id,
          role: @role,
          content: scrub(@content),
          tool_name: scrub(@tool_name),
          tool_call_id: scrub(@tool_call_id),
          token_count: @token_count,
          metadata_json: @metadata.empty? ? nil : JSON.generate(@metadata),
          created_at: @created_at
        }
      end

      # Returns a hash for LLM context building. A user message that collapsed a
      # large paste keeps the compact "[Pasted text #N …]" placeholder in its
      # stored/displayed content (#213); here we expand each placeholder back to
      # its full body for the model, so the provider sees everything while the
      # transcript echo (live AND on resume) stays clean.
      def to_context
        msg = { role: @role, content: expand_pastes(@content) }
        msg[:tool_call_id] = @tool_call_id if @tool_call_id
        msg[:name] = @tool_name if @tool_name
        # Surface assistant tool_calls (persisted as metadata) so the adapter
        # can rebuild the toolUse block expected by strict providers on resume.
        msg[:tool_calls] = @metadata[:tool_calls] if @metadata.is_a?(Hash) && @metadata[:tool_calls]
        # #583: re-derive the error flag from the persisted outcome so a
        # denied/errored tool result replays to the model marked as an error
        # (is_error) on the next turn, exactly as it was sent live — never as a
        # plain result the model can confabulate over. Old rows lack the keys
        # and hydrate as a normal (non-error) tool result, unchanged.
        msg[:is_error] = true if @role == "tool" && tool_outcome_errored?
        msg
      end

      private

      # True when this tool row's persisted outcome (status / error_code, written
      # by Agent::Loop#persist_tool_result) marks it as denied or errored — the
      # signal that re-flags the replayed tool_result as an error for the model
      # (#583). status is stored as a String ("denied"/"error"); a present
      # error_code (any value) is the #errorish? soft-failure signal.
      def tool_outcome_errored?
        return false unless @metadata.is_a?(Hash)

        status = @metadata[:status].to_s
        return true if %w[denied error].include?(status)

        !@metadata[:error_code].to_s.empty?
      end

      # Strip persist-fatal bytes (NUL et al.) from a free-text column at the
      # write seam (#498), preserving nil so a content-less tool/assistant row
      # round-trips as nil rather than "".
      def scrub(value)
        value.nil? ? nil : Util::Output.scrub_utf8(value)
      end

      # Substitutes each stored [token, body] paste expansion back into +text+.
      # The pairs are stored as an array (not a hash) so the placeholder tokens
      # survive the metadata JSON round-trip without being mangled into symbols.
      def expand_pastes(text)
        return text unless text.is_a?(String) && @metadata.is_a?(Hash)

        Array(@metadata[:paste_expansions]).reduce(text) do |acc, (token, body)|
          token && body ? acc.gsub(token, body) : acc
        end
      end
    end
  end
end
