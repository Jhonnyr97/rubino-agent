# frozen_string_literal: true

require "net/http"
require "json"
require "uri"
require_relative "inline_think_filter"

module Rubino
  module LLM
    # Direct Bedrock runtime client using Bearer token authentication.
    # Used when BEDROCK_API_KEY is set without BEDROCK_SECRET_KEY.
    # Calls the Bedrock Converse API with Authorization: Bearer header.
    # Supports tool calls via the native Bedrock Converse toolConfig format.
    class BedrockBearerClient
      BEDROCK_RUNTIME_HOST = "bedrock-runtime.%s.amazonaws.com"

      def initialize(api_key:, region:, model_id:, show_reasoning: false, event_bus: nil)
        @api_key        = api_key
        @region         = region
        @model_id       = model_id
        @host           = BEDROCK_RUNTIME_HOST % region
        @show_reasoning = show_reasoning
        @event_bus      = event_bus
      end

      # Sends a non-streaming chat request, returns AdapterResponse
      def chat(messages:, tools: nil)
        body     = build_body(messages, tools: tools)
        response = post("/model/#{URI.encode_uri_component(@model_id)}/converse", body)
        parse_response(response)
      end

      # Sends a "streaming" chat request and returns an AdapterResponse, yielding
      # chunk HASHES shaped exactly like every other adapter:
      #   { type: :content | :thinking, text: String, message_id: Integer }
      #
      # Real Bedrock ConverseStream (binary eventstream) is out of scope: bearer-
      # token auth isn't supported by ruby_llm's SigV4 Bedrock provider, and this
      # is a plain Net::HTTP transport. We buffer the non-streaming /converse
      # response FULLY, then replay it through InlineThinkFilter in slices so the
      # SHAPE matches the streaming contract (typed deltas, :thinking channel,
      # a single content block id, an explicit MESSAGE_COMPLETED boundary).
      # Only the token cadence is synthetic.
      #
      # INVARIANT: we buffer the entire response BEFORE the first emit. That is
      # what makes retrying this call (now in Agent::ModelCallRunner) safe — a
      # transport error can only fire during post() (before any chunk reached the
      # UI), never mid-replay, so a retry can't double output.
      def stream(messages:, tools: nil, &block)
        body = build_body(messages, tools: tools)
        data = post("/model/#{URI.encode_uri_component(@model_id)}/converse", body)

        # Single buffered content block ⇒ message_id is always 0. Mirrors the
        # 2-arg emit lambda RubyLLMAdapter feeds into InlineThinkFilter.feed/flush.
        emit = lambda do |type, text|
          return if text.nil? || text.empty?
          return if type == :thinking && !@show_reasoning

          block&.call({ type: type, text: text, message_id: 0 })
        end

        think_filter = InlineThinkFilter.new
        extract_text(data).chars.each_slice(5) do |slice|
          think_filter.feed(slice.join, &emit)
        end
        think_filter.flush(&emit)

        @event_bus&.emit(Interaction::Events::MESSAGE_COMPLETED, message_id: 0)

        parse_response(data)
      end

      private

      def build_body(messages, tools: nil)
        system_msgs = messages.select { |m| role_of(m) == "system" }
        chat_msgs   = messages.reject { |m| role_of(m) == "system" }

        body = {
          messages: chat_msgs.map { |m| format_message(m) }
        }

        body[:system] = system_msgs.map { |m| { text: content_of(m).to_s } } if system_msgs.any?

        # Attach tool definitions when provided
        if tools && !tools.empty?
          body[:toolConfig] = {
            tools: tools.map { |t| format_tool(t) }
          }
        end

        body
      end

      # Format a message for the Bedrock Converse API.
      # Handles plain text, assistant tool_use turns, and tool_result turns.
      def format_message(msg)
        role    = role_of(msg)
        content = content_of(msg)
        tc      = msg[:tool_calls] || msg["tool_calls"]

        case role
        when "assistant"
          # Assistant message with tool use blocks
          if tc && !tc.empty?
            content_blocks = []
            content_blocks << { text: content.to_s } if content && !content.to_s.empty?
            tc.each do |call|
              content_blocks << {
                toolUse: {
                  toolUseId: call[:id] || call["id"],
                  name: call[:name] || call["name"],
                  input: call[:arguments] || call["arguments"] || {}
                }
              }
            end
            { role: "assistant", content: content_blocks }
          else
            { role: "assistant", content: [{ text: content.to_s }] }
          end
        when "tool"
          # Tool result — Bedrock expects role: "user" with toolResult content block
          {
            role: "user",
            content: [{
              toolResult: {
                toolUseId: msg[:tool_call_id] || msg["tool_call_id"] || "unknown",
                content: [{ text: content.to_s }]
              }
            }]
          }
        else
          { role: role, content: [{ text: content.to_s }] }
        end
      end

      # Format a tool definition for Bedrock toolConfig.
      # Accepts Rubino::Tools::Base instances or plain hashes with
      # :name/:description/:parameters keys.
      def format_tool(tool)
        if tool.respond_to?(:name)
          name        = tool.name
          description = tool.description
          schema      = tool.input_schema
        else
          name        = tool[:name] || tool["name"]
          description = tool[:description] || tool["description"]
          schema      = tool[:parameters] || tool["parameters"] || {}
        end

        {
          toolSpec: {
            name: name,
            description: description,
            inputSchema: { json: schema }
          }
        }
      end

      def post(path, body)
        uri = URI("https://#{@host}#{path}")
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = true
        http.read_timeout = 120
        http.open_timeout = 30

        request = Net::HTTP::Post.new(uri.path)
        request["Authorization"] = "Bearer #{@api_key}"
        request["Content-Type"]  = "application/json"
        request["Accept"]        = "application/json"
        request.body = JSON.generate(body)

        response = http.request(request)

        unless response.code.to_i == 200
          error_body = begin
            JSON.parse(response.body)
          rescue StandardError
            { "message" => response.body }
          end
          raise Rubino::Error, "Bedrock error #{response.code}: #{error_body["message"] || error_body}"
        end

        JSON.parse(response.body)
      end

      def parse_response(data)
        text       = extract_text(data)
        tool_calls = extract_tool_calls(data)

        input_tokens  = data.dig("usage", "inputTokens")  || 0
        output_tokens = data.dig("usage", "outputTokens") || 0

        Rubino::LLM::AdapterResponse.new(
          content: text,
          tool_calls: tool_calls,
          input_tokens: input_tokens,
          output_tokens: output_tokens,
          model_id: @model_id
        )
      end

      def extract_text(data)
        data.dig("output", "message", "content")
            &.select { |c| c["text"] }
            &.map    { |c| c["text"] }
            &.join("") || ""
      end

      # Extract tool use blocks from a Bedrock Converse response.
      # Returns an array of { id:, name:, arguments: } hashes.
      def extract_tool_calls(data)
        content_blocks = data.dig("output", "message", "content") || []
        content_blocks.filter_map do |block|
          next unless block["toolUse"]

          tu = block["toolUse"]
          {
            id: tu["toolUseId"],
            name: tu["name"],
            arguments: tu["input"] || {}
          }
        end
      end

      def role_of(msg)
        (msg[:role] || msg["role"]).to_s
      end

      def content_of(msg)
        msg[:content] || msg["content"]
      end
    end
  end
end
