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
        # The /skills toggle verbs (#188) — the same registry-validated
        # StateRepository write the HTTP API and `rubino skills` CLI run.
        TOGGLE_VERBS = %w[enable disable].freeze

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

          return show_skills if arg.nil?

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
            @ui.info("Add .md files to .rubino/skills/ to create skills.")
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
        end

        # Wraps "<head><description>" to the terminal width, breaking only on
        # whitespace, with continuation lines indented to the description column.
        def wrap_skill_line(head, description)
          width = terminal_width
          indent = " " * head.length
          avail  = [width - head.length, 20].max

          lines = []
          current = +""
          description.split(/\s+/).each do |word|
            candidate = current.empty? ? word : "#{current} #{word}"
            if candidate.length > avail && !current.empty?
              lines << current
              current = word.dup
            else
              current = candidate
            end
          end
          lines << current unless current.empty?
          lines = [""] if lines.empty?

          lines.each_with_index.map { |line, i| (i.zero? ? head : indent) + line }
        end

        def terminal_width
          cols = IO.console&.winsize&.last
          cols&.positive? ? cols : 80
        rescue StandardError
          80
        end
      end
    end
  end
end
