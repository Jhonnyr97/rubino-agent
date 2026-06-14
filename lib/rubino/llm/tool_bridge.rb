# frozen_string_literal: true

require "ruby_llm"

module Rubino
  module LLM
    # Wraps a Rubino::Tools::Base instance into a RubyLLM::Tool subclass
    # so that ruby_llm can register it, serialize its schema to the LLM, and
    # dispatch tool calls through our full execution pipeline.
    #
    # When a ToolExecutor is provided (always the case in production), tool
    # execution goes through:
    #   ApprovalPolicy → tool.call() → truncation → ToolCallRepository.record
    #
    # This ensures identical behavior regardless of LLM provider — there is
    # now a single tool-execution path in the entire application.
    module ToolBridge
      # Returns a RubyLLM::Tool instance wrapping agent_tool.
      #
      # call_id_provider: a 0-arity callable returning the id of the tool_call
      # ruby_llm is about to dispatch (captured by the adapter's
      # before_tool_call callback). Threaded through so the STREAMING path
      # populates the same call_id the non-streaming Loop#execute_tool_calls
      # already passes — which is what makes spill_full_output fire and the
      # messages.tool_call_id / tool_calls metadata persist (STRM-2). nil in
      # the test/one-shot fallback path, where the bridge calls tool.call
      # directly and no real id exists.
      # Anthropic prompt-cache breakpoint (#311) placed on the LAST tool's wire
      # definition. RubyLLM's Anthropic::Tools.function_for deep_merges a tool's
      # provider_params onto its wire def, and Anthropic caches the WHOLE tool
      # block up to and including the breakpoint — so one cache_control on the
      # final tool caches every tool definition.
      CACHE_CONTROL_PROVIDER_PARAMS = { cache_control: { type: "ephemeral" } }.freeze

      def self.for(agent_tool, ui: nil, event_bus: nil, tool_executor: nil, call_id_provider: nil,
                   cache_breakpoint: false)
        klass = bridge_class_for(agent_tool.name)
        klass.new(agent_tool,
                  ui: ui || Rubino.ui,
                  event_bus: event_bus || Rubino.event_bus,
                  tool_executor: tool_executor,
                  call_id_provider: call_id_provider,
                  cache_breakpoint: cache_breakpoint)
      end

      # Registers every Rubino tool (wrapped as a bridge) on a ruby_llm chat AND
      # wires the call-id capture the streaming path needs. ruby_llm hands the
      # bridge only the parsed arguments (Tool#call(args)), not the tool_call
      # object — so we latch the id from the before_tool_call callback (fired
      # right before each sequential, tool_concurrency=false dispatch) into a
      # holder the bridge reads back as call_id. Without this the streaming path
      # has no id and spill_full_output / messages.tool_call_id die (STRM-2).
      def self.install(chat, tools, ui: nil, event_bus: nil, tool_executor: nil, cache_tools: false)
        current_call_id = nil
        chat.before_tool_call { |tc| current_call_id = tc&.id } if chat.respond_to?(:before_tool_call)
        list = Array(tools)
        # #311: cache the whole tool block by putting a single cache_control
        # breakpoint on the LAST tool. Tools arrive in the registry's
        # deterministic insertion order (register_defaults!), so "last" is
        # stable across turns — the cache key over the tool block holds.
        last_index = list.size - 1
        list.each_with_index do |tool, idx|
          chat.with_tool(self.for(tool, ui: ui, event_bus: event_bus,
                                        tool_executor: tool_executor,
                                        call_id_provider: -> { current_call_id },
                                        cache_breakpoint: cache_tools && idx == last_index))
        end
      end

      def self.bridge_class_for(tool_name)
        @cache ||= {}
        @cache[tool_name] ||= build_class(tool_name)
      end

      def self.build_class(tool_name)
        klass = Class.new(::RubyLLM::Tool) do
          define_method(:name) { tool_name }

          define_method(:initialize) do |agent_tool, ui:, event_bus:, tool_executor:,
                                          call_id_provider: nil, cache_breakpoint: false|
            @agent_tool       = agent_tool
            @ui               = ui
            @event_bus        = event_bus
            @tool_executor    = tool_executor
            @call_id_provider = call_id_provider
            @cache_breakpoint = cache_breakpoint
          end

          define_method(:description) { @agent_tool.description }
          define_method(:params_schema) { @agent_tool.input_schema }

          # PER-INSTANCE provider_params (#311). RubyLLM::Tool#provider_params
          # is normally class-level, but bridge classes are CACHED and shared
          # across tools/turns — a class-level write would leak the breakpoint
          # onto every tool of that name. Overriding per instance keeps the
          # cache_control on exactly the one final tool the installer marked.
          define_method(:provider_params) do
            @cache_breakpoint ? Rubino::LLM::ToolBridge::CACHE_CONTROL_PROVIDER_PARAMS : {}
          end

          define_method(:execute) do |**kwargs|
            name = @agent_tool.name
            args = kwargs.transform_keys(&:to_s)

            if @tool_executor
              # Full pipeline: approval check → tool.call → truncation → audit record.
              # Thread the real tool_call id (captured by the adapter's
              # before_tool_call callback) so the streaming path populates the
              # spill file + tool_call_id/tool_calls linkage exactly like the
              # non-streaming Loop#execute_tool_calls (STRM-2).
              call_id = @call_id_provider&.call
              result = @tool_executor.execute(
                name: name,
                arguments: args,
                call_id: call_id
              )
              result.output
            else
              # Fallback: direct call (tests / one-shot mode without full Lifecycle)
              @event_bus&.emit(Rubino::Interaction::Events::TOOL_STARTED, name: name)
              @ui&.tool_started(name, arguments: args)

              begin
                output = @agent_tool.call(args)
                result = Rubino::Tools::Result.success(
                  name: name, call_id: nil, output: output.to_s
                )
                @event_bus&.emit(Rubino::Interaction::Events::TOOL_FINISHED, name: name)
                @ui&.tool_finished(name, result: result)
                result.output
              rescue StandardError => e
                @event_bus&.emit(Rubino::Interaction::Events::TOOL_FINISHED, name: name)
                @ui&.tool_finished(name)
                "Error: #{e.message}"
              end
            end
          end
        end

        const_name = "Bridge_#{tool_name.gsub(/[^a-zA-Z0-9]/, "_")}"
        unless Rubino::LLM::ToolBridge.const_defined?(const_name, false)
          Rubino::LLM::ToolBridge.const_set(const_name, klass)
        end

        klass
      end
    end
  end
end
