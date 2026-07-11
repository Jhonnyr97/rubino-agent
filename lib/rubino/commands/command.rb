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
      attr_reader :name, :description, :agent, :model, :path, :argument_hint

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
      #
      # The file is read as UTF-8 EXPLICITLY, independent of the process locale
      # (#273): under a bare C/POSIX locale the default external encoding is
      # US-ASCII, so File.read returns an ASCII-tagged string and gsub!-ing a
      # UTF-8 prompt with it raises Encoding::CompatibilityError on the first
      # non-ASCII byte. Forcing UTF-8 makes reading a UTF-8 prompt file work
      # regardless of LANG/LC_ALL.
      def process_file_references!(prompt)
        prompt.gsub!(%r{@([\w/._-]+)}) do
          file_path = Regexp.last_match(1)
          expanded  = File.expand_path(file_path)
          if File.exist?(expanded)
            File.read(expanded, encoding: "UTF-8")
          else
            "@#{file_path} (file not found)"
          end
        end
      end

      def shell_injection_enabled?
        Rubino.configuration.dig("commands", "shell_injection_enabled") == true
      end

      def parse!
        # Read the command template as UTF-8 regardless of the process locale
        # (#273): a bare C/POSIX locale would otherwise tag it US-ASCII and later
        # string ops against UTF-8 prompt content raise Encoding::CompatibilityError.
        raw = File.read(@path, encoding: "UTF-8")

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

        # Scan the rendered template body for prompt injection before it
        # becomes a user message, mirroring Hermes's context-file scanning.
        @template = Security::ContentScanner.scan(@template, source: @path)

        @name          = (@metadata["name"] || File.basename(@path, ".md")).to_s
        @description   = @metadata["description"] || ""
        @argument_hint = @metadata["argument-hint"] || @metadata["argument_hint"]
        @agent         = @metadata["agent"]
        @model         = @metadata["model"]
      end

      def load_template
        @template
      end
    end
  end
end
