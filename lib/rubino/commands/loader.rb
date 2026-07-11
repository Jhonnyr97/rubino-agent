# frozen_string_literal: true

module Rubino
  module Commands
    # Discovers and manages custom slash commands from configured paths.
    class Loader
      COMMAND_GLOB = "*.md"

      # Claude Code / everything-claude-code ecosystem compatibility paths.
      # Scanned BEFORE the rubino-specific paths so a same-named command in
      # .rubino/commands or ~/.rubino/commands overrides the Claude copy. The
      # project-local `.claude/commands` is trust-gated exactly like
      # `.rubino/commands` (project_local_path? check below).
      CLAUDE_PATHS = [".claude/commands", "~/.claude/commands"].freeze

      def initialize(config: nil, include_project_local: nil)
        @config = config || Rubino.configuration
        # Auto-trust-gate: when the caller doesn't say, check folder-trust.
        # Explicit true/false wins (tests, cross-cutting overrides).
        @include_project_local = if include_project_local.nil?
                                   self.class.project_local_trusted?
                                 else
                                   include_project_local
                                 end
        @commands = {}
        @discovered = false
      end

      # Discovers all available commands
      def discover!
        @commands.clear
        command_paths.each do |dir|
          expanded = self.class.resolve_path(dir)
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
        @commands[name.to_s.sub(%r{\A/}, "")]
      end

      # Returns true if input starts with a slash command
      def slash_command?(input)
        input.strip.start_with?("/")
      end

      # A bare `/` (or slash + only whitespace) is a misfire, not a prompt and
      # not a command: it parses to the built-in `commands` listing so it shows
      # the roster instead of burning an LLM turn (bare `/`, which would parse to
      # a nil name) or reporting "unknown command: /" (`/ foo`, which would parse
      # to an empty command name). Keeps the misfire handled in one place so the
      # REPL dispatcher needs no special case.
      BARE_SLASH_COMMAND = "commands"

      # Parses a slash command input into [command_name, arguments]
      def parse(input)
        stripped = input.strip
        return nil unless stripped.start_with?("/")

        parts = stripped[1..].split(/\s+/, 2)
        command_name = parts[0]
        arguments = parts[1] || ""
        # `/` alone, or `/` followed by only whitespace, has no command name —
        # show the roster rather than dispatch a real turn / "unknown command".
        return [BARE_SLASH_COMMAND, ""] if command_name.nil? || command_name.empty?

        [command_name, arguments]
      end

      # Returns command names for autocomplete
      def names
        all.map { |c| "/#{c.name}" }
      end

      private

      def command_paths
        paths = @config.dig("commands", "paths") ||
                Config::Defaults.to_hash.dig("commands", "paths")
        # Prepended (not appended) so the rubino paths override Claude paths
        # on a name collision (later entries win in discover!'s hash merge).
        paths = CLAUDE_PATHS + Array(paths)
        unless @include_project_local
          # Untrusted primary root: drop the project-local (cwd-relative)
          # command dirs, keeping only absolute / home (~) paths.
          paths = paths.reject { |p| project_local_path?(p) }
        end
        paths
      end

      # Default search paths, with the home sentinel resolved to a real dir.
      # Used by the loader and the "/commands" empty-state copy so both report
      # the directories actually searched (RUBINO_HOME-aware).
      def self.default_command_paths
        Array(Config::Defaults.to_hash.dig("commands", "paths")).map { |p| resolve_path(p) }
      end

      # Resolves a configured commands path to an absolute directory, expanding
      # the <RUBINO_HOME>/commands sentinel against the resolved home
      # (RUBINO_HOME -> else ~/.rubino) instead of a literal ~/.rubino (#38).
      def self.resolve_path(dir)
        if dir.to_s.start_with?(Config::Defaults::HOME_COMMANDS_PATH)
          suffix = dir.to_s.sub(Config::Defaults::HOME_COMMANDS_PATH, "")
          File.join(Config::Loader.default_home_path, "commands#{suffix}")
        else
          File.expand_path(dir)
        end
      end

      # Mirrors Skills::Registry.project_local_trusted?: trust-gate the cwd,
      # but never let the check itself break discovery on a real error.
      def self.project_local_trusted?
        Rubino::Trust.trusted?(Rubino::Workspace.primary_root)
      rescue StandardError
        true
      end

      # A command path is "project-local" when it resolves under the primary
      # workspace root (the cwd a hostile repo could ship commands in), as
      # opposed to an absolute or ~ path the user owns. Sentinel paths like
      # <RUBINO_HOME>/commands are home-relative, never project-local.
      def project_local_path?(path)
        return false if path.to_s.start_with?("~", "/", "<")

        expanded = canonical_dir(File.expand_path(path.to_s))
        root = canonical_dir(File.expand_path(Workspace.primary_root))
        expanded == root || expanded.start_with?("#{root}#{File::SEPARATOR}")
      rescue StandardError
        true
      end

      def canonical_dir(path)
        (File.realpath(path) if File.exist?(path)) || path
      rescue StandardError
        path
      end
    end
  end
end
