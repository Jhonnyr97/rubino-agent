# frozen_string_literal: true

module Rubino
  module Skills
    # Discovers and manages skills from configured paths.
    # Skills are loaded lazily - metadata is parsed upfront but
    # full content is only loaded when the skill is invoked.
    class Registry
      # Flat-file skills: <dir>/<name>.md (legacy, kept for back-compat).
      FLAT_GLOB = "*.md"
      # Directory skills: <dir>/<name>/SKILL.md (Claude skill layout).
      DIR_GLOB = File.join("*", "SKILL.md")

      def initialize(config: nil, state_repository: nil)
        @config = config || Rubino.configuration
        @state_repository = state_repository
        @skills = {}
        @discovered = false
      end

      # Discovers all available skills from configured paths. Both the flat
      # layout (<name>.md) and the directory layout (<name>/SKILL.md) are
      # supported. When a name collides, the directory skill wins (it is the
      # richer unit: it can carry bundled references/scripts/assets).
      def discover!
        previously_discovered = @discovered
        known_before = @skills.keys
        @skills.clear
        skill_paths.each do |dir|
          expanded = File.expand_path(dir)
          next unless File.directory?(expanded)

          add_skills(Dir.glob(File.join(expanded, FLAT_GLOB)))
          add_skills(Dir.glob(File.join(expanded, DIR_GLOB)))
        end
        @discovered = true
        # Skill CREATION has no in-process tool — the agent writes files — so the
        # cleanest available signal is a RE-scan surfacing a skill we hadn't seen
        # before. Only count on a re-discover (not the first scan, which is just
        # initial enumeration) so existing skills aren't booked as "created".
        count_created!(known_before) if previously_discovered
        @skills
      end

      # Returns all discovered skills (discovers on first call)
      def all
        discover! unless @discovered
        @skills.values
      end

      # Finds a skill by name
      def find(name)
        discover! unless @discovered
        @skills[name.to_s]
      end

      # Returns skill summaries for prompt inclusion (names + descriptions only).
      # Disabled skills (per StateRepository) are excluded so a skill toggled
      # off never appears in the system-prompt index (Skills::PromptIndex).
      def summaries
        enabled.map(&:summary)
      end

      # Loads and returns the full content of a skill by name. Returns nil when
      # the skill is unknown; the disabled case is surfaced by #enabled? so the
      # caller (SkillTool) can give a distinct "disabled" message.
      def load_skill(name)
        skill = find(name)
        return nil unless skill

        skill.content
      end

      # Returns skill names
      def names
        all.map(&:name)
      end

      # Skills not toggled off in the StateRepository (default-enabled when no
      # row exists). Single source of truth for the enabled-filter shared by the
      # system-prompt index (via #summaries) and the `skill` tool (via this).
      def enabled
        all.select { |skill| enabled?(skill.name) }
      end

      # Whether a skill is enabled (default-enabled when no state row exists).
      def enabled?(name)
        state_repository.enabled?(name)
      end

      private

      # Increments +skills_created_total+ once per skill name that appears in a
      # re-scan but was absent from the prior scan. NOTE: this is the only clean
      # in-process creation signal available (there is no skill-creation tool);
      # a skill created on disk is therefore counted the next time the registry
      # re-discovers, not at write time. A skill removed and re-added would be
      # re-counted — acceptable for a usage signal, not a ledger.
      def count_created!(known_before)
        new_names = @skills.keys - known_before
        return if new_names.empty?

        Rubino::Metrics.counter(:skills_created_total).increment(by: new_names.size)
      end

      def state_repository
        @state_repository ||= StateRepository.new
      end

      # Builds a Skill per path and indexes it by name. Called with flat paths
      # first, then directory paths, so directory skills override flat ones on
      # a name collision (see #discover!).
      def add_skills(paths)
        paths.each do |path|
          skill = Skill.new(path: path)
          @skills[skill.name] = skill
        end
      end

      def skill_paths
        @config.dig("skills", "paths") || [
          ".rubino/skills",
          "~/.rubino/skills"
        ]
      end
    end
  end
end
