# frozen_string_literal: true

require "thor"

module Rubino
  module CLI
    # Subcommands for managing skills (#188). `list` mirrors the in-chat
    # /skills disclosure (enabled/disabled markers), `show` prints a skill's
    # SKILL.md body (trust review before enabling), and `enable`/`disable`
    # run the SAME registry-validated StateRepository write the HTTP API
    # toggle and the in-chat `/skills enable|disable` use (Skills::Toggle) —
    # no new logic, just the missing terminal surface.
    class SkillsCommand < Thor
      # Clean `tree`/help label instead of the underscored class-name default (F12).
      namespace "rubino skills"

      def self.exit_on_failure?
        true
      end

      desc "list", "List skills with enabled/disabled markers"
      def list
        Rubino.ensure_database_ready!
        registry = Skills::Registry.trusted
        skills = registry.all
        if skills.empty?
          Rubino.ui.info("No skills found.")
          Rubino.ui.info("Add .md files to .rubino/skills/ to create skills.")
          return
        end

        rows = skills.map do |skill|
          [skill.name, skill_status(skill.name, registry), skill.description.to_s]
        end
        Rubino.ui.table(headers: %w[Name Status Description], rows: rows)
      end

      desc "show NAME", "Print a skill's SKILL.md body (review it before enabling)"
      def show(name)
        skill = Skills::Registry.trusted.find(name)
        if skill.nil?
          Rubino.ui.error("unknown skill: #{name}")
          return
        end

        Rubino.ui.info(skill.content)
      end

      desc "enable NAME", "Enable a skill (back into the index, every session)"
      def enable(name)
        toggle(name, enabled: true)
      end

      desc "disable NAME", "Disable a skill (drops out of the index, every session)"
      def disable(name)
        toggle(name, enabled: false)
      end

      private

      # The Status cell: enabled/disabled from the StateRepository (the same
      # source the in-chat list's "(disabled)" marker reads), plus the active
      # pin when this process carries one (the slot is process-level, so a
      # fresh CLI run normally shows none — the marker matters in-process).
      def skill_status(name, registry)
        status = registry.enabled?(name) ? "enabled" : "disabled"
        status += " · active" if Rubino::ActiveSkill.current == name
        status
      end

      def toggle(name, enabled:)
        Rubino.ensure_database_ready!
        registry = Skills::Registry.trusted
        unless Skills::Toggle.set(name, enabled: enabled, registry: registry)
          Rubino.ui.error("unknown skill: #{name}")
          available = registry.names
          Rubino.ui.info("Available: #{available.join(", ")}") unless available.empty?
          return
        end

        Rubino.ui.success("#{enabled ? "Enabled" : "Disabled"} skill: #{name}")
      end
    end
  end
end
