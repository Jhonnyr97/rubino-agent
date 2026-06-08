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
      def self.for(agent_tool, ui: nil, event_bus: nil, tool_executor: nil)
        klass = bridge_class_for(agent_tool.name)
        klass.new(agent_tool,
                  ui:            ui            || Rubino.ui,
                  event_bus:     event_bus     || Rubino.event_bus,
                  tool_executor: tool_executor)
      end

      def self.bridge_class_for(tool_name)
        @cache ||= {}
        @cache[tool_name] ||= build_class(tool_name)
      end

      def self.build_class(tool_name)
        klass = Class.new(::RubyLLM::Tool) do
          define_method(:name) { tool_name }

          define_method(:initialize) do |agent_tool, ui:, event_bus:, tool_executor:|
            @agent_tool    = agent_tool
            @ui            = ui
            @event_bus     = event_bus
            @tool_executor = tool_executor
          end

          define_method(:description) { @agent_tool.description }
          define_method(:params_schema) { @agent_tool.input_schema }

          define_method(:execute) do |**kwargs|
            name = @agent_tool.name
            args = kwargs.transform_keys(&:to_s)

            if @tool_executor
              # Full pipeline: approval check → tool.call → truncation → audit record
              result = @tool_executor.execute(
                name:      name,
                arguments: args,
                call_id:   nil
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
