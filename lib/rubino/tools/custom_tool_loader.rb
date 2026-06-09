# frozen_string_literal: true

module Rubino
  module Tools
    # Loads user-defined tools from .rubino/tools/ directories.
    # Users can define tools using a simple Ruby DSL.
    #
    # Example tool file (.rubino/tools/my_tool.rb):
    #
    #   Rubino.define_tool do
    #     name "my_custom_tool"
    #     description "Does something custom"
    #     input_schema type: "object", properties: { input: { type: "string" } }
    #     risk_level :low
    #
    #     execute do |args|
    #       "Result: #{args['input']}"
    #     end
    #   end
    #
    class CustomToolLoader
      TOOL_GLOB = "*.rb"

      # HOME-only by design (#44). This loader `load`s arbitrary Ruby, so it
      # must NEVER read from a project's cwd `.rubino/tools` — that would let
      # any directory you start rubino in execute code with zero prompt, the
      # exact foot-gun the folder-trust model exists to prevent. The only
      # allowed source is the user's own config dir under RUBINO_HOME, which is
      # not attacker-controllable by cd-ing into a repo. (Previously the path
      # list led with the cwd `.rubino/tools`; that entry is removed.)
      def self.tool_paths
        [File.join(Rubino.home_path, "tools")]
      end

      def initialize(paths: nil)
        @paths = paths || self.class.tool_paths
      end

      # Loads all custom tools and registers them
      def load_all!
        loaded = 0

        @paths.each do |dir|
          expanded = File.expand_path(dir)
          next unless File.directory?(expanded)

          Dir.glob(File.join(expanded, TOOL_GLOB)).each do |path|
            load_tool_file(path)
            loaded += 1
          rescue StandardError => e
            Rubino.ui.warning("Failed to load tool #{path}: #{e.message}")
          end
        end

        loaded
      end

      private

      def load_tool_file(path)
        # Load in a clean context
        load(path)
      end
    end

    # DSL builder for custom tools
    class CustomToolBuilder
      attr_reader :_name, :_description, :_input_schema, :_risk_level, :_execute_block

      def initialize
        @_risk_level = :low
        @_input_schema = { type: "object", properties: {} }
      end

      def name(val)
        @_name = val
      end

      def description(val)
        @_description = val
      end

      def input_schema(val)
        @_input_schema = val
      end

      def risk_level(val)
        @_risk_level = val
      end

      def execute(&block)
        @_execute_block = block
      end

      # Builds a Tool instance from the DSL
      def build
        builder = self
        Class.new(Base) do
          define_method(:name) { builder._name }
          define_method(:description) { builder._description }
          define_method(:input_schema) { builder._input_schema }
          define_method(:risk_level) { builder._risk_level }
          define_method(:call) { |args| builder._execute_block.call(args) }
        end.new
      end
    end
  end
end

# Module-level DSL method for defining custom tools
module Rubino
  def self.define_tool(&)
    builder = Tools::CustomToolBuilder.new
    builder.instance_eval(&)
    tool = builder.build
    Tools::Registry.register(tool)
    tool
  end
end
