# frozen_string_literal: true

require "yaml"

module Rubino
  module Commands
    # Represents a custom slash command loaded from a Markdown file.
    # Supports $ARGUMENTS, $1-$9 positional params, @file refs.
    #
    # Shell injection via !`command` is opt-in and disabled by default.
    # Enable it by setting commands.shell_injection_enabled: true in your
    # configuration — only do so in trusted, controlled environments.
    class Command
      attr_reader :name, :description, :agent, :model, :path

      def initialize(path:)
        @path     = path
        @metadata = {}
        @template = nil
        parse!
      end

      # Renders the command prompt with given arguments.
      def render(arguments = "")
        prompt = template.dup

        substitute_arguments!(prompt, arguments)
        process_shell_injections!(prompt)
        process_file_references!(prompt)

        prompt.strip
      end

      # Returns the raw template content.
      def template
        @template ||= load_template
      end

      private

      # Replace $ARGUMENTS and positional $1..$9 params.
      def substitute_arguments!(prompt, arguments)
        prompt.gsub!("$ARGUMENTS", arguments)

        args = arguments.split(/\s+/)
        (1..9).each do |i|
          prompt.gsub!("$#{i}", args[i - 1] || "")
        end
      end

      # Process !`command` shell injections — only when explicitly enabled.
      def process_shell_injections!(prompt)
        return unless shell_injection_enabled?

        prompt.gsub!(/!`([^`]+)`/) do
          command = Regexp.last_match(1)
          `#{command} 2>&1`.strip
        end
      end

      # Replace @path/to/file references with file content.
      def process_file_references!(prompt)
        prompt.gsub!(%r{@([\w/._-]+)}) do
          file_path = Regexp.last_match(1)
          expanded  = File.expand_path(file_path)
          if File.exist?(expanded)
            File.read(expanded)
          else
            "@#{file_path} (file not found)"
          end
        end
      end

      def shell_injection_enabled?
        Rubino.configuration.dig("commands", "shell_injection_enabled") == true
      end

      def parse!
        raw = File.read(@path)

        if raw.start_with?("---")
          parts = raw.split("---", 3)
          if parts.size >= 3
            begin
              @metadata = YAML.safe_load(parts[1], permitted_classes: [Symbol]) || {}
            rescue Psych::SyntaxError => e
              warn "rubino: skipping malformed frontmatter in #{@path} " \
                   "(line #{e.line}: #{e.problem}); treating whole file as template"
              @metadata = {}
              @template = raw
            end
            unless @metadata.is_a?(Hash)
              warn "rubino: ignoring non-Hash frontmatter in #{@path}; treating whole file as template"
              @metadata = {}
              @template = raw
            end
            @template ||= parts[2].strip
          else
            @template = raw
          end
        else
          @template = raw
        end

        @name        = (@metadata["name"] || File.basename(@path, ".md")).to_s
        @description = @metadata["description"] || ""
        @agent       = @metadata["agent"]
        @model       = @metadata["model"]
      end

      def load_template
        @template
      end
    end
  end
end
