# frozen_string_literal: true

require_relative "adapter_response"
require_relative "scenario_loader"
require_relative "scenario_selector"

module Rubino
  module LLM
    # Dev-only LLM adapter that replays a pre-recorded YAML scenario instead
    # of hitting a real provider. The public surface mirrors RubyLLMAdapter
    # so Agent::Loop can swap it in without further plumbing changes.
    #
    # Selection:
    #   - model_id starting with "fake/" pins the scenario (suffix is the name).
    #   - otherwise ScenarioSelector.resolve(last_user_message_content) chooses
    #     one based on keyword routing, falling back to "happy-path".
    #
    # Streaming:
    #   - "content"  → yield { type: :content,  text: ... }
    #   - "thinking" → yield { type: :thinking, text: ... } (gated by
    #                  display.show_reasoning, mirroring RubyLLMAdapter)
    #   - "tool_call"     → buffered onto the final AdapterResponse (NOT yielded
    #                  mid-stream; this matches RubyLLMAdapter and is what Loop
    #                  expects).
    #   - "delay_seconds" → cancellable sleep between events.
    #   - unknown    → logged and skipped.
    #
    # Cancellation is checked between each event so Esc / Ctrl+C lands within
    # one tick instead of waiting for the full scenario to drain.
    class FakeProvider
      attr_reader :model_id, :provider

      DEFAULT_DELAY = 0.1

      def initialize(model_id: nil, provider: nil, config: nil, ui: nil, event_bus: nil,
                     tool_executor: nil, cancel_token: nil)
        @config        = config || Rubino.configuration
        @model_id      = model_id || @config.model_default || "fake/happy-path"
        @provider      = provider || "fake"
        @ui            = ui
        @event_bus     = event_bus
        @tool_executor = tool_executor
        @cancel_token  = cancel_token
      end

      # LLM boundary entry: dispatch an LLM::Request to the
      # streaming vs non-streaming transport. Mirrors RubyLLMAdapter#call so Loop
      # can drive the fake through the same seam.
      def call(request, &block)
        if request.stream?
          stream(messages: request.messages, tools: request.tools,
                 image_paths: request.image_paths, &block)
        else
          chat(messages: request.messages, tools: request.tools,
               image_paths: request.image_paths)
        end
      end

      # Non-streaming entry point. Plays the scenario with a no-op block and
      # returns the accumulated AdapterResponse.
      def chat(messages:, tools: nil, response_format: nil, image_paths: nil)
        stream(messages: messages, tools: tools, response_format: response_format,
               image_paths: image_paths) { |_chunk| }
      end

      # Streaming entry point. Yields chunk hashes shaped exactly like
      # RubyLLMAdapter:
      #   { type: :content,  text: String }
      #   { type: :thinking, text: String }
      # Returns AdapterResponse with concatenated content, accumulated
      # tool_calls, zero usage tokens, and the model id.
      def stream(messages:, tools: nil, response_format: nil, image_paths: nil, &block)
        # image_paths is accepted for signature parity with RubyLLMAdapter
        # (Loop passes it on every call). FakeProvider plays back recorded
        # scenarios verbatim, so it has nothing to do with attachments.
        _ = image_paths
        # If the runner is calling us back after a tool result, replaying the
        # original scenario would re-emit the same tool_call indefinitely
        # (FakeProvider has no inter-turn state). Detect the post-tool turn
        # and emit a short closing message instead so the run terminates.
        events =
          if post_tool_turn?(messages)
            closing_events
          else
            scenario_name = pick_scenario(messages)
            ScenarioLoader.load(scenario_name, scenarios_dir: scenarios_dir_from_config)
          end
        # {{input}} is the only placeholder scenarios currently use. The reference
        # had a richer template system, but in practice every scenario only
        # interpolated the user input. Keep it simple until a scenario actually
        # needs more (e.g. {{session_id}}).
        @scenario_vars = { "input" => extract_last_user_text(messages).to_s }

        buffered    = +""
        tool_calls  = []

        events.each do |event|
          @cancel_token&.check!
          dispatch_event(event, buffered: buffered, tool_calls: tool_calls, &block)
        end

        AdapterResponse.new(
          content:       buffered,
          tool_calls:    tool_calls,
          input_tokens:  0,
          output_tokens: 0,
          model_id:      @model_id
        )
      rescue Rubino::Interrupted
        # Mirror RubyLLMAdapter: surface whatever was buffered as a clean
        # AdapterResponse instead of swallowing the partial output.
        return AdapterResponse.new(
          content:       buffered || "",
          tool_calls:    tool_calls || [],
          input_tokens:  0,
          output_tokens: 0,
          model_id:      @model_id
        )
      end

      def model_info
        nil
      end

      def context_window
        @config.model_context_length || 128_000
      end

      # Convenience: returns the scenario name FakeProvider would pick for
      # this set of messages. Useful in specs and the doctor command.
      def resolve_scenario(messages)
        pick_scenario(messages)
      end

      private

      def dispatch_event(event, buffered:, tool_calls:, &block)
        type = event["type"] || event[:type]
        case type.to_s
        when "content"
          text = interpolate(event["text"] || event[:text])
          return if text.nil? || text.empty?
          buffered << text
          # Single buffered scenario turn ⇒ one content block ⇒ message_id 0,
          # matching the uniform chunk contract every adapter emits.
          safe_yield(block, type: :content, text: text, message_id: 0)
        when "thinking"
          text = interpolate(event["text"] || event[:text])
          return if text.nil? || text.empty?
          return if reasoning_hidden?
          safe_yield(block, type: :thinking, text: text, message_id: 0)
        when "tool_call"
          tool_calls << build_tool_call(event)
        when "delay_seconds"
          seconds = event["value"] || event[:value] || DEFAULT_DELAY
          cancellable_sleep(seconds.to_f)
        else
          log_safely(event: "llm.fake.unknown_event", type: type.to_s)
        end
      end

      # Substitutes {{var}} placeholders using @scenario_vars. Returns the
      # text unchanged when nothing matches so scenario authors can mix
      # static and templated chunks freely.
      def interpolate(text)
        return text if text.nil? || text.empty? || @scenario_vars.nil?
        @scenario_vars.reduce(text) { |acc, (k, v)| acc.gsub("{{#{k}}}", v.to_s) }
      end

      def extract_last_user_text(messages)
        return "" unless messages.is_a?(Array)
        last = messages.reverse.find { |m| (m[:role] || m["role"]).to_s == "user" }
        return "" unless last
        content = last[:content] || last["content"]
        case content
        when String then content
        when Array
          content.filter_map { |part| part.is_a?(Hash) ? (part[:text] || part["text"]) : nil }.join(" ")
        else
          content.to_s
        end
      end

      def safe_yield(block, payload)
        return unless block
        block.call(payload)
      rescue StandardError => e
        # UI hiccups must not abort the stream. Mirror RubyLLMAdapter#emit.
        log_safely(event: "llm.fake.emit_error", error: e.message, type: payload[:type])
      end

      def build_tool_call(event)
        id        = event["id"]        || event[:id]        || "fake_call_#{SecureRandom.hex(4)}"
        name      = event["name"]      || event[:name]      || event["tool"] || event[:tool]
        arguments = event["arguments"] || event[:arguments] || {}

        # Loop / ToolBridge expect string-keyed arguments. Normalise here so
        # scenario authors can use either symbol or string keys in the YAML.
        normalised_args =
          if arguments.is_a?(Hash)
            arguments.each_with_object({}) { |(k, v), h| h[k.to_s] = v }
          else
            arguments
          end

        { id: id, name: name, arguments: normalised_args }
      end

      def pick_scenario(messages)
        if @model_id.to_s.start_with?("fake/")
          suffix = @model_id.to_s.sub(%r{\Afake/}, "")
          return suffix unless suffix.empty?
        end
        ScenarioSelector.resolve(last_user_message_content(messages))
      end

      # True when the runner is calling us back IN THE SAME TURN, right
      # after a tool result — i.e. the very last message has role "tool".
      # In a multi-turn session there are usually older tool results from
      # previous runs in the history; those must NOT flip us into the
      # closing-content path, only an immediately-preceding tool result
      # does. Checking just the tail handles both cases.
      def post_tool_turn?(messages)
        return false unless messages.is_a?(Array)
        last = messages.last
        return false unless last.is_a?(Hash)
        (last[:role] || last["role"]).to_s == "tool"
      end

      # A minimal closing turn: a short content chunk and nothing else. Returns
      # the events array the scenario dispatcher expects.
      def closing_events
        [ { "type" => "content", "text" => "Done." } ]
      end

      def last_user_message_content(messages)
        return "" if messages.nil? || messages.empty?

        last_user = messages.reverse.find do |m|
          role = (m[:role] || m["role"]).to_s
          role == "user"
        end
        last_user ||= messages.last
        last_user[:content] || last_user["content"] || ""
      end

      def reasoning_hidden?
        Config::ReasoningPrefs.mode(@config) == :hidden
      end

      # Pulls the override scenarios directory off the adapter's own config
      # so tests (which build a one-off configuration via test_configuration)
      # don't have to mutate the global Rubino.configuration.
      def scenarios_dir_from_config
        @config.dig("fake_provider", "scenarios_dir") ||
          @config.dig("providers", "fake", "scenarios_dir")
      rescue StandardError
        nil
      end

      def cancellable_sleep(seconds)
        return if seconds <= 0
        deadline = monotonic_now + seconds
        while (remaining = deadline - monotonic_now).positive?
          @cancel_token&.check!
          sleep([0.05, remaining].min)
        end
      end

      def monotonic_now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      def log_safely(**fields)
        Rubino.logger.warn(**fields)
      rescue StandardError
        # nothing to do
      end
    end
  end
end

require "securerandom"
