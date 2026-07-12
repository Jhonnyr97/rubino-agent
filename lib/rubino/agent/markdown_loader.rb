# frozen_string_literal: true

require "yaml"

module Rubino
  module Agent
    # Loads agent definitions from Markdown files (`.md` with YAML frontmatter)
    # in the Claude Code / everything-claude-code AGENT format. Each file
    # becomes a rubino `Agent::Definition`, registered into the existing
    # `AgentRegistry` via #register.
    #
    # Scanned directories (low-to-high precedence):
    #   1. ~/.claude/agents/*.md       (user-level, Claude-ecosystem)
    #   2. ~/.rubino/agents/*.md       (user-level, rubino-specific)
    #   3. .claude/agents/*.md         (project-local, Claude-ecosystem)
    #   4. .rubino/agents/*.md         (project-local, rubino-specific)
    #
    # Within each tier, files are registered in alphabetical order; later
    # tiers override earlier ones on a name collision. A file-defined agent
    # whose name collides with a BUILT-IN agent (build, plan, explore,
    # general, compaction, title) REPLACES that built-in — project- and
    # user-level files explicitly author over built-in defaults.
    #
    # Project-local directories (`.claude/agents`, `.rubino/agents`) are
    # trust-gated via Rubino::Trust — when the primary workspace root is
    # untrusted, project-local agents are skipped (same gate as skills/commands).
    class MarkdownLoader
      # Scan order: low precedence first, so later registrations overwrite.
      SCAN_DIRS = [
        "~/.claude/agents",
        "~/.rubino/agents",
        ".claude/agents",
        ".rubino/agents"
      ].freeze

      AGENT_GLOB = "*.md"

      # ------------------------------------------------------------------
      # Model aliases from Claude Code shorthand to concrete model IDs.
      # "inherit" + nil → resolve to nil (use the global default).
      # Full model IDs (e.g. "claude-sonnet-4-5") pass through unchanged.
      # ------------------------------------------------------------------
      MODEL_ALIASES = {
        "sonnet" => "claude-sonnet-4-5",
        "opus" => "claude-opus-4-5",
        "haiku" => "claude-haiku-4-5",
        "inherit" => nil
      }.freeze

      # ------------------------------------------------------------------
      # Claude Code tool names → rubino tool names.
      # PascalCase Claude names map to rubino's snake_case names.
      # Unknown names are dropped with a warning.
      # ------------------------------------------------------------------
      TOOL_NAME_MAP = {
        "Bash" => "shell",
        "Glob" => "glob",
        "Grep" => "grep",
        "Read" => "read",
        "Write" => "write",
        "Edit" => "edit",
        "MultiEdit" => "multi_edit",
        "WebSearch" => "web_search",
        "WebFetch" => "web_fetch",
        "Task" => "task",
        "TaskOutput" => "task_result",
        "TaskStop" => "task_stop",
        "AskUserQuestion" => "question",
        "TodoWrite" => "todo",
        "NotepadEdit" => "memory",
        "Skill" => "skill",
        "EnterPlanMode" => nil # plan mode is a mode switch, not a tool — skip
      }.freeze

      # Agent files with no `type` frontmatter default to :subagent (Claude
      # Code agents are subagents by nature). Explicit `type: primary` in
      # frontmatter changes this; anything else stays subagent.
      DEFAULT_TYPE = :subagent

      # Trust-gate the cwd (mirrors Commands::Loader + Skills::Registry).
      def self.project_local_trusted?
        Rubino::Trust.trusted?(Rubino::Workspace.primary_root)
      rescue StandardError
        true
      end

      # Fields with no rubino equivalent: silently note and ignore.
      IGNORED_FIELDS = %w[
        color effort isolation skills initialPrompt background
      ].freeze

      def initialize(registry:, include_project_local: nil)
        @registry = registry
        @include_project_local = if include_project_local.nil?
                                   self.class.project_local_trusted?
                                 else
                                   include_project_local
                                 end
      end

      # Scans all directories, parses each .md file, and registers the
      # resulting Definition into the registry. Returns the count of agents
      # loaded (including those that collided with and replaced a previously
      # registered definition).
      def load!
        count = 0
        scan_dirs.each do |dir|
          expanded = File.expand_path(dir)
          next unless File.directory?(expanded)

          Dir.glob(File.join(expanded, AGENT_GLOB)).each do |path|
            definition = parse_file(path)
            next unless definition

            @registry.register(definition)
            count += 1
          end
        end
        count
      end

      private

      def scan_dirs
        if @include_project_local
          SCAN_DIRS
        else
          SCAN_DIRS.reject { |d| project_local_dir?(d) }
        end
      end

      def project_local_dir?(dir)
        return false if dir.start_with?("~", "/")

        expanded = canonical_dir(File.expand_path(dir))
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

      def parse_file(path)
        raw = File.read(path, encoding: "UTF-8")
        return nil unless raw.start_with?("---")

        parts = raw.split("---", 3)
        return nil unless parts.size >= 3

        metadata = parse_metadata(parts[1], path)
        return nil if metadata.nil? || metadata["name"].to_s.strip.empty?

        body = parts[2].strip
        build_definition(metadata, body, path)
      rescue StandardError => e
        Rubino.logger.warn(
          event: "agent.md.load_error",
          path: path,
          error: e.class.name,
          message: e.message
        )
        nil
      end

      def parse_metadata(yaml_str, path)
        parsed = YAML.safe_load(yaml_str, permitted_classes: [Symbol]) || {}
        unless parsed.is_a?(Hash)
          Rubino.logger.warn(
            event: "agent.md.nonhash_frontmatter",
            path: path
          )
          return nil
        end
        parsed
      rescue Psych::SyntaxError => e
        Rubino.logger.warn(
          event: "agent.md.malformed_frontmatter",
          path: path,
          line: e.line,
          problem: e.problem
        )
        nil
      end

      def build_definition(meta, body, path)
        name = meta["name"].to_s.strip
        description = (meta["description"] || "").to_s.strip
        type = resolve_type(meta["type"])
        model = resolve_model(meta["model"])
        tools = resolve_tools(meta["tools"], name, path)
        permissions = resolve_permissions(meta, name, path)
        mcp_servers = resolve_mcp_servers(meta["mcpServers"])
        max_turns = resolve_max_turns(meta["maxTurns"])

        # Fields with no rubino equivalent: silently note and ignore.
        note_ignored(meta, name, path)

        # Scan the body (agent system prompt) for prompt injection before it
        # becomes part of the system prompt, mirroring Hermes's context-file
        # scanning. Use the path as the source for diagnosability.
        scanned_body = Security::ContentScanner.scan(body, source: path)

        Definition.new(
          name: name,
          type: type,
          description: description,
          system_prompt: scanned_body,
          model: model,
          tools: tools,
          permissions: permissions,
          mcp_servers: mcp_servers,
          max_turns: max_turns
        )
      end

      # ------------------------------------------------------------------
      # Type resolution
      # ------------------------------------------------------------------

      def resolve_type(raw)
        return DEFAULT_TYPE if raw.nil? || raw.to_s.strip.empty?

        case raw.to_s.strip.downcase
        when "primary" then :primary
        when "utility" then :utility
        else :subagent
        end
      end

      # ------------------------------------------------------------------
      # Model resolution
      # ------------------------------------------------------------------

      def resolve_model(raw)
        return nil if raw.nil? || raw.to_s.strip.empty?

        key = raw.to_s.strip.downcase
        if MODEL_ALIASES.key?(key)
          MODEL_ALIASES[key]
        else
          # Full model ID — pass through unchanged.
          key
        end
      end

      # ------------------------------------------------------------------
      # Tool translation
      # ------------------------------------------------------------------

      def resolve_tools(raw, agent_name, path)
        return :all if raw.nil? || raw.to_s.strip.empty?

        claude_names = raw.to_s.split(/[\s,]+/).map(&:strip).reject(&:empty?)
        translated = claude_names.filter_map do |cn|
          mapped = TOOL_NAME_MAP[cn]
          if mapped.nil? && !TOOL_NAME_MAP.key?(cn)
            Rubino.logger.warn(
              event: "agent.md.unknown_tool",
              agent: agent_name,
              path: path,
              tool: cn
            )
            next nil
          end
          mapped
        end

        translated.empty? ? :all : translated
      end

      # ------------------------------------------------------------------
      # Permissions + disallowedTools → deny rules
      # ------------------------------------------------------------------

      def resolve_permissions(meta, agent_name, path)
        rules = {}

        # permissionMode mapping:
        #   "default" / "acceptEdits" → no extra rules (rubino's default
        #     is already ask-on-dangerous).
        #   "plan" → read-only (but that's tools, not permissions — handled
        #     via tools: translate if agent file doesn't list tools).
        #   "bypassPermissions" → NO equivalent in rubino (rubino has no
        #     "bypass all prompts" mode for subagents); warn and skip.
        perm_mode = meta["permissionMode"].to_s.strip.downcase
        case perm_mode
        when "bypasspermissions"
          Rubino.logger.warn(
            event: "agent.md.bypass_permissions",
            agent: agent_name,
            path: path
          )
        end

        # disallowedTools → deny entries in the permissions hash.
        # Supports both space/comma-separated string and array.
        disallowed = extract_string_list(meta["disallowedTools"])
        disallowed.each do |cn|
          rn = translate_tool_name_for_deny(cn)
          if rn
            rules["#{rn} *"] = "deny"
          else
            Rubino.logger.warn(
              event: "agent.md.unknown_deny_tool",
              agent: agent_name,
              path: path,
              tool: cn
            )
          end
        end

        rules.empty? ? nil : rules
      end

      # ------------------------------------------------------------------
      # MCP servers
      # ------------------------------------------------------------------

      def resolve_mcp_servers(raw)
        return nil if raw.nil? || raw.to_s.strip.empty?

        servers = extract_string_list(raw)
        servers.empty? ? nil : servers
      end

      # ------------------------------------------------------------------
      # Max turns
      # ------------------------------------------------------------------

      def resolve_max_turns(raw)
        return nil if raw.nil?

        Integer(raw)
      rescue ArgumentError, TypeError
        nil
      end

      def note_ignored(meta, agent_name, path)
        IGNORED_FIELDS.each do |field|
          next unless meta.key?(field) && !meta[field].nil?

          Rubino.logger.debug(
            event: "agent.md.ignored_field",
            agent: agent_name,
            path: path,
            field: field
          )
        end

        # `skills` in Claude Code agents refers to attaching skill files
        # at agent creation time. Rubino skills are loaded via the system
        # prompt / skill tool — the `skills` field on an agent definition
        # has no equivalent. Note it separately so the message is clear.
      end

      # ------------------------------------------------------------------
      # Helpers
      # ------------------------------------------------------------------

      # Parses a space/comma-separated string or an array into a flat
      # array of non-empty strings.
      def extract_string_list(raw)
        return [] if raw.nil?

        case raw
        when Array
          raw.map(&:to_s).map(&:strip).reject(&:empty?)
        when String
          raw.split(/[\s,]+/).map(&:strip).reject(&:empty?)
        else
          []
        end
      end

      # Translates a Claude Code tool name for a deny-rule pattern.
      # Returns the rubino tool name, or nil if unmappable.
      def translate_tool_name_for_deny(claude_name)
        TOOL_NAME_MAP[claude_name]
      end
    end
  end
end
