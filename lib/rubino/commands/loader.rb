# frozen_string_literal: true

module Rubino
  module Commands
    # Discovers and manages custom slash commands from configured paths.
    class Loader
      COMMAND_GLOB = "*.md"

      def initialize(config: nil)
        @config = config || Rubino.configuration
        @commands = {}
        @discovered = false
      end

      # Discovers all available commands
      def discover!
        @commands.clear
        command_paths.each do |dir|
          expanded = File.expand_path(dir)
          next unless File.directory?(expanded)

          Dir.glob(File.join(expanded, COMMAND_GLOB)).each do |path|
            cmd = Command.new(path: path)
            @commands[cmd.name] = cmd
          end
        end
        @discovered = true
        @commands
      end

      # Returns all discovered commands
      def all
        discover! unless @discovered
        @commands.values
      end

      # Finds a command by name (without the leading /)
      def find(name)
        discover! unless @discovered
        @commands[name.to_s.sub(/\A\//, "")]
      end

      # Returns true if input starts with a slash command
      def slash_command?(input)
        input.strip.start_with?("/")
      end

      # Parses a slash command input into [command_name, arguments]
      def parse(input)
        stripped = input.strip
        return nil unless stripped.start_with?("/")

        parts = stripped[1..].split(/\s+/, 2)
        command_name = parts[0]
        arguments = parts[1] || ""
        [command_name, arguments]
      end

      # Returns command names for autocomplete
      def names
        all.map { |c| "/#{c.name}" }
      end

      private

      def command_paths
        @config.dig("commands", "paths") || [
          ".rubino/commands",
          "~/.rubino/commands"
        ]
      end
    end
  end
end
