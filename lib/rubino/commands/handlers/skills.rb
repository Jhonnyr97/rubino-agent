# frozen_string_literal: true

module Rubino
  module Commands
    module Handlers
      # The `/skills` list/activate/enable/disable surface, extracted from
      # Commands::Executor (batch B).
      #
      # `/skills`                 → list (unchanged behavior).
      # `/skills <name>`          → ACTIVATE that skill for the session (sticky).
      #                             The name is validated against the registry; an
      #                             unknown OR DISABLED name errors and leaves the
      #                             active skill unchanged.
      # `/skills none`            → CLEAR the active skill (also the `✗ none`
      #                             picker entry, whose spliced label is
      #                             normalized here).
      # `/skills enable <name>`   → persistently re-enable a skill (#188) — the
      # `/skills disable <name>`    same StateRepository write the HTTP API
      #                             toggle and the `rubino skills` CLI verbs run
      #                             (Skills::Toggle), affecting EVERY session,
      #                             unlike the session-scoped activation.
      #
      # The active skill is stored in Rubino::ActiveSkill (a process-level slot,
      # mirroring Rubino::Modes) so it survives across turns and is force-loaded
      # into the system prompt each turn (Context::PromptAssembler).
      class Skills
        include Display

        # The /skills toggle verbs (#188) — the same registry-validated
        # StateRepository write the HTTP API and `rubino skills` CLI run.
        TOGGLE_VERBS = %w[enable disable].freeze

        # Explicit synonyms for the LIST action, so `/skills list` shows the
        # catalogue instead of being mis-parsed as "activate the skill named
        # 'list'" (which errored with `✗ unknown skill: list`).
        LIST_VERBS = %w[list ls].freeze

        def initialize(ui:)
          @ui = ui
        end

        def handle_skills(arguments)
          tokens = arguments.to_s.strip.split(/\s+/)
          if TOGGLE_VERBS.include?(tokens.first.to_s.downcase)
            toggle_skill(tokens[1], enabled: tokens.first.casecmp?("enable"))
            return
          end

          arg = normalize_skill_arg(arguments)

          return show_skills if arg.nil? || LIST_VERBS.include?(arg.downcase)

          if clear_skill_arg?(arg)
            previous = Rubino::ActiveSkill.current
            Rubino::ActiveSkill.clear
            if previous
              @ui.success("Cleared active skill (was: #{previous}).")
            else
              @ui.info("No active skill.")
            end
            return
          end

          # Trust-aligned discovery (#63): activate only skills the assembler
          # will actually pin — in an untrusted cwd a project-local skill is
          # refused (with a reason) instead of chip-active-but-not-injected.
          registry = Rubino::Skills::Registry.trusted
          skill = registry.find(arg)
          unless skill
            if Rubino::Skills::Registry.new.find(arg)
              @ui.error("skill #{arg} is in this directory's .rubino/skills, but the directory " \
                        "isn't trusted — its SKILL.md would not be loaded, so it can't be activated")
            else
              @ui.error("unknown skill: #{arg}")
              available = registry.names
              @ui.info("Available: #{available.join(", ")}") unless available.empty?
            end
            return
          end

          # A disabled skill is EXCLUDED from activation (#188): the assembler
          # refuses to inject it (active_skill_block checks enabled?), so pinning
          # it would show an active chip with no effect.
          unless registry.enabled?(skill.name)
            @ui.error("skill #{skill.name} is disabled — /skills enable #{skill.name} to use it")
            return
          end

          Rubino::ActiveSkill.set(skill.name)
          @ui.success("Active skill: #{skill.name} (loaded into context for this session).")
        end

        private

        # `/skills enable|disable <name>` (#188) — the missing human surface for
        # the StateRepository toggle (previously HTTP-API-only). Persisted, so it
        # affects the Level-1 index of every session until toggled back.
        def toggle_skill(name, enabled:)
          verb = enabled ? "enable" : "disable"
          if name.to_s.strip.empty?
            @ui.info("Usage: /skills #{verb} <name>")
            return
          end

          registry = Rubino::Skills::Registry.trusted
          unless Rubino::Skills::Toggle.set(name, enabled: enabled, registry: registry)
            @ui.error("unknown skill: #{name}")
            available = registry.names
            @ui.info("Available: #{available.join(", ")}") unless available.empty?
            return
          end

          if enabled
            @ui.success("Enabled skill: #{name} (back in the skills index for every session).")
          else
            clear_disabled_active_skill(name)
            @ui.success("Disabled skill: #{name} (out of the index for every session; " \
                        "/skills enable #{name} to restore).")
          end
        end

        # Disabling the skill that is currently PINNED active would leave a lying
        # chip — the assembler silently drops a disabled active skill — so the
        # pin is cleared with a note instead.
        def clear_disabled_active_skill(name)
          return unless Rubino::ActiveSkill.current == name

          Rubino::ActiveSkill.clear
          @ui.info("(it was the active skill — pin cleared)")
        end

        # The single argument to `/skills`, trimmed; nil when no argument was
        # given (bare `/skills` → list). The picker splices the `✗ none` label, so
        # the leading `✗ ` marker is stripped here to recover the bare token.
        def normalize_skill_arg(arguments)
          raw = arguments.to_s.strip.sub(/\A✗\s+/, "")
          # Only the FIRST token is the skill name (skill names are single tokens).
          token = raw.split(/\s+/).first
          token unless token.nil? || token.empty?
        end

        # True when the argument means "clear the active skill" (the `none`
        # sentinel, case-insensitive — the `✗ ` marker was already stripped).
        def clear_skill_arg?(arg)
          arg.casecmp?(Rubino::ActiveSkill::NONE)
        end

        def show_skills
          registry = Rubino::Skills::Registry.trusted
          skills = registry.all
          if skills.empty?
            @ui.info("No skills found.")
          else
            active = Rubino::ActiveSkill.current
            skills.each do |skill|
              status = registry.enabled?(skill.name) ? "" : " (disabled)"
              status += " (active)" if active && active == skill.name
              head   = "  #{skill.name}#{status} - "
              # Word-wrap the description so a long one breaks on spaces instead of
              # being hard-wrapped mid-word by the terminal at the right edge
              # (B8 — "officia\nl"). Continuation lines hang-indent under the
              # description so the list stays readable.
              wrap_skill_line(head, skill.description.to_s).each { |line| @ui.info(line) }
            end
          end
          explain_authoring(any: !skills.empty?)
        end

        # The authoring affordance, shown EVERY time (not just on an empty list),
        # to bring /skills to parity with /commands' rich empty-state. A skill is
        # a Markdown file with name/description frontmatter under a skills dir;
        # name the REAL searched paths (RUBINO_HOME-aware), the SKILL.md format,
        # and a concrete one-liner so authoring is discoverable in-app rather
        # than only via the docs (QA: /skills under-discoverable vs /commands).
        def explain_authoring(any:)
          @ui.blank_line
          intro = any ? "Add your own:" : "Create one:"
          @ui.info("#{intro} a skill is a Markdown file with name/description frontmatter")
          @ui.info("in a skills directory (a flat <name>.md, or <name>/SKILL.md for a directory skill).")
          @ui.blank_line
          @ui.info("Searched: #{skill_dirs.join(", ")}")
          @ui.info("Create one, e.g. .rubino/skills/data-helper/SKILL.md:")
          @ui.blank_line
          @ui.info("    ---")
          @ui.info("    name: data-helper")
          @ui.info("    description: Helps wrangle CSV data. Use when cleaning or reshaping data.")
          @ui.info("    ---")
          @ui.info("    Step-by-step instructions the agent loads when the skill is active.")
        end

        # The directories the registry actually searches for skills, for the
        # authoring copy. Mirrors Registry#skill_paths + #resolve_path so the
        # "Searched:" line reports the real (RUBINO_HOME-aware) paths rather than
        # a literal ~/.rubino never searched. Best-effort: a config hiccup falls
        # back to the stock relative/home pair.
        # The user-writable skills directories, for the "Searched:" line —
        # resolved the SAME way the registry resolves them (RUBINO_HOME-aware),
        # so the copy reports the real paths rather than a literal ~/.rubino
        # never searched. Read straight from config/defaults (not via a registry
        # instance) so the in-TUI list path stays decoupled from discovery. The
        # read-only gem-bundled dir is intentionally NOT listed: authoring is
        # about where the USER adds skills.
        def skill_dirs
          paths = Rubino.configuration.dig("skills", "paths")
          paths = Rubino::Config::Defaults.to_hash.dig("skills", "paths") if paths.nil?
          paths = [".rubino/skills", "~/.rubino/skills"] if paths.nil?
          Array(paths).map { |dir| Rubino::Skills::Registry.resolve_path_for(dir) }.uniq
        rescue StandardError
          [".rubino/skills", "~/.rubino/skills"]
        end
      end
    end
  end
end
