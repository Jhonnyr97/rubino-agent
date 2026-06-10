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

      # Skills shipped *inside the gem* (skills/<name>/SKILL.md at the gem
      # root, packaged via the gemspec's git-ls-files list). These are
      # ALWAYS discovered — they don't depend on the user's skills.paths
      # config (which `setup` freezes into config.yml) and they survive the
      # folder-trust filter because this is an absolute path under the
      # installed gem, owned by the user, not anything a visited repo can
      # influence. This is how built-in skills (e.g. ruby-expert) reach every
      # install with no copy step and update automatically on gem upgrade.
      BUILTIN_SKILLS_DIR = File.expand_path("../../../skills", __dir__)

      # +include_project_local+ controls whether the cwd `.rubino/skills`
      # catalogue is discovered. Folder-trust passes false for an UNtrusted
      # primary root so a hostile repo's skill descriptions can't be auto-
      # injected into the system prompt before the user vouches for the folder
      # (the home `~/.rubino/skills` catalogue is always loaded — it's the
      # user's own, not attacker-controllable by cd-ing into a repo).
      # +include_builtin+ controls whether the gem-bundled BUILTIN_SKILLS_DIR is
      # scanned. Always on in production (built-ins ship with every install).
      # When left nil it falls back to the `skills.include_builtin` config key
      # (default true), so a caller that only has the config — like the prompt
      # assembler, which builds its own Registry — can still opt out; tests that
      # assert an exact catalogue pass false to isolate from the shipped skills.
      def initialize(config: nil, state_repository: nil, include_project_local: true, include_builtin: nil)
        @config = config || Rubino.configuration
        @state_repository = state_repository
        @include_project_local = include_project_local
        @include_builtin = include_builtin.nil? ? (@config.dig("skills", "include_builtin") != false) : include_builtin
        @skills = {}
        @discovered = false
      end

      # A registry aligned with the prompt assembler's folder-trust gate (#63):
      # in an untrusted cwd the project-local catalogue is excluded, so the
      # /skills picker and activation surface only skills the assembler will
      # actually pin into the system prompt — never a chip claiming an active
      # skill whose SKILL.md is withheld.
      def self.trusted(**)
        new(include_project_local: project_local_trusted?, **)
      end

      # Mirrors Context::PromptAssembler#project_local_trusted?: trust-gate the
      # cwd, but never let the check itself break discovery on a real error.
      def self.project_local_trusted?
        Rubino::Trust.trusted?(Rubino::Workspace.primary_root)
      rescue StandardError
        true
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
          expanded = resolve_path(dir)
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

      # Resolves a configured skills dir to an absolute path. The stock
      # "~/.rubino/..." entries follow the resolved home (RUBINO_HOME → else
      # ~/.rubino), same resolver config/.env/DB/commands use, so an isolated
      # home actually has its skills discovered (#135) instead of the literal
      # path expanding against the REAL home. Any other path expands verbatim.
      def resolve_path(dir)
        if dir.to_s == "~/.rubino" || dir.to_s.start_with?("~/.rubino/")
          File.join(Config::Loader.default_home_path, dir.to_s.delete_prefix("~/.rubino"))
        else
          File.expand_path(dir)
        end
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
        paths = @config.dig("skills", "paths") || [
          ".rubino/skills",
          "~/.rubino/skills"
        ]
        unless @include_project_local
          # Untrusted primary root: drop the project-local (cwd-relative) skill
          # dirs, keeping only absolute / home (~) paths the user controls.
          paths = paths.reject { |p| project_local_path?(p) }
        end

        # Built-in (gem-bundled) skills are scanned FIRST so a user skill of the
        # same name — discovered later in .rubino/skills or ~/.rubino/skills —
        # overrides the built-in on the registry's name-indexed merge (last
        # writer wins in #add_skills). That lets a user shadow/customize a
        # shipped skill while still getting the built-ins for free by default.
        @include_builtin ? [BUILTIN_SKILLS_DIR, *paths] : paths
      end

      # A skill path is "project-local" when it resolves under the primary
      # workspace root (the cwd a hostile repo could ship skills in), as
      # opposed to an absolute or ~/.rubino path the user owns.
      def project_local_path?(path)
        return false if path.to_s.start_with?("~", "/")

        expanded = File.expand_path(path.to_s)
        root = File.expand_path(Workspace.primary_root)
        expanded == root || expanded.start_with?("#{root}#{File::SEPARATOR}")
      rescue StandardError
        # Conservative: if we can't tell, treat as project-local and drop it.
        true
      end
    end
  end
end
