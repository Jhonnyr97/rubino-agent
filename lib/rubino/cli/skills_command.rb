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
    #
    # `install`/`update`/`remove` (#4) manage skills fetched from git repos
    # (Skills::Installer): any repo shipping the registry's `<name>/SKILL.md`
    # layout is a source — no marketplace, nothing vendored in the gem.
    class SkillsCommand < Thor
      # Clean `tree`/help label instead of the underscored class-name default (F12).
      namespace "rubino skills"

      # The `--documents` shorthand (#4): Anthropic's four document skills.
      DOCUMENTS_SOURCE = "anthropics/skills"
      DOCUMENT_SKILLS  = %w[pdf docx pptx xlsx].freeze

      def self.exit_on_failure?
        true
      end

      # How to AUTHOR a skill — the verb table only covers install/enable/etc,
      # so `rubino skills help` never told you a skill is just a Markdown file
      # you write yourself (QA: authoring under-discoverable). Append a short
      # create note to the subcommand listing, mirroring the in-chat `/skills`
      # authoring footer. Only decorate the verb table itself, not a per-verb
      # help page (`rubino skills help install`), which super handles unchanged.
      AUTHORING_NOTE = "Create a skill: add a Markdown file with name/description frontmatter " \
                       "to a skills dir\n(.rubino/skills/<name>/SKILL.md, or a flat .rubino/skills/<name>.md). " \
                       "See `rubino skills show <name>` for the format."

      # rubocop:disable Style/OptionalBooleanParameter -- overrides Thor's own
      # `def help(shell, subcommand = false)` positional signature.
      def self.help(shell, subcommand = false)
        super
        return if subcommand

        shell.say
        shell.say(AUTHORING_NOTE)
      end
      # rubocop:enable Style/OptionalBooleanParameter

      # Drop Thor's inherited `tree` so its banner doesn't render the doubled
      # "rubino rubino skills tree" (#327); the top-level `rubino tree` covers it.
      remove_command :tree

      desc "list", "List skills with enabled/disabled markers"
      def list
        Rubino.ensure_database_ready!
        registry = Skills::Registry.trusted
        skills = registry.all
        if skills.empty?
          Rubino.ui.info("No skills found.")
          Rubino.ui.info("Add .md files to .rubino/skills/ to create skills.")
          warn_untrusted_hidden_skills(skills)
          return
        end

        sources = Skills::Installer.new.sources
        rows = skills.map do |skill|
          [skill.name, skill_status(skill.name, registry), provenance(skill.name, sources),
           skill.description.to_s]
        end
        Rubino.ui.table(headers: %w[Name Status Source Description], rows: rows)
        warn_untrusted_hidden_skills(skills)
      end

      desc "show NAME", "Print a skill's SKILL.md body (review it before enabling)"
      def show(name)
        skill = Skills::Registry.trusted.find(name)
        # Not-found is a FAILURE on the automation surface (P2-H1/H2): raise so
        # exit_on_failure? exits non-zero with the message on stderr, matching
        # SessionCommand. ui.error wrote to stdout and returned 0.
        raise Thor::Error, "unknown skill: #{name}" if skill.nil?

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

      desc "install [SOURCE]", "Install skills from a git repo (owner/repo shorthand or git URL)"
      option :skill, type: :string, repeatable: true,
                     desc: "Skill name to install from the source (repeatable)"
      option :all,   type: :boolean, desc: "Install every skill found in the source"
      option :list,  type: :boolean, desc: "Only list the skills discoverable in the source"
      option :documents, type: :boolean,
                         desc: "Shorthand for #{DOCUMENTS_SOURCE} with #{DOCUMENT_SKILLS.join("/")}"
      def install(source = nil)
        wanted = Array(options[:skill])
        if options[:documents]
          source ||= DOCUMENTS_SOURCE
          wanted = DOCUMENT_SKILLS.dup if wanted.empty?
        end
        # Missing source / no-skills / fetch failure are all FAILURES on the
        # automation surface (P2-H1/H2): raise Thor::Error so the run exits
        # non-zero with the message on stderr instead of stdout-printing and
        # returning 0.
        raise Thor::Error, "missing source — pass owner/repo, a git URL, or --documents" if source.nil?

        installer = Skills::Installer.new
        fetched = installer.fetch(source) do |checkout, sha|
          found = installer.discover(checkout)
          if found.empty?
            raise Thor::Error, "no skills found in #{source} (expected <name>/SKILL.md directories)"
          elsif options[:list]
            discovered_table(found)
          else
            install_selected(installer, found, wanted, checkout: checkout, source: source, commit: sha)
          end

          true
        end
        raise Thor::Error, "could not fetch #{source} — check the source name/URL and your network" if fetched.nil?
      end

      desc "update [NAME ...]", "Re-fetch installed skills from their recorded sources"
      def update(*names)
        installer = Skills::Installer.new
        if installer.sources.empty?
          Rubino.ui.info("No skills installed via `rubino skills install` yet.")
          return
        end

        # Report every name's outcome, but if ANY failed (unknown / fetch
        # failed), exit non-zero so automation detects the partial failure
        # (P2-H1). Per-name error lines go to stderr (warn), successes/notices
        # stay on stdout.
        failures = []
        installer.update(names).each do |name, status|
          case status
          when :updated     then Rubino.ui.success("Updated skill: #{name}")
          when :up_to_date  then Rubino.ui.info("#{name} is up to date.")
          when :unknown
            warn "✗ unknown skill: #{name} (not installed via `rubino skills install`)"
            failures << name
          else
            warn "✗ could not update #{name} — fetch failed or the skill left its source"
            failures << name
          end
        end
        raise Thor::Error, "failed to update: #{failures.join(", ")}" unless failures.empty?
      end

      desc "remove NAME", "Remove a skill installed via `rubino skills install`"
      def remove(name)
        installer = Skills::Installer.new
        if installer.remove(name)
          Rubino.ui.success("Removed skill: #{name}")
          return
        end

        # Nothing removed — a FAILURE (P2-H1/H2). The "delete manually" hint
        # goes to stderr alongside the error, then raise so exit != 0.
        dir = File.join(installer.skills_dir, name)
        warn "It exists at #{dir} — delete the directory manually." if File.directory?(dir)
        raise Thor::Error, "#{name} wasn't installed via `rubino skills install` (no provenance entry)"
      end

      private

      # Trust hint (#369a): the listing above uses the trust-gated registry, so
      # in an UNtrusted cwd a project-local `.rubino/skills` catalogue is silently
      # withheld and the user only sees built-ins/home skills — with no clue the
      # repo's skills exist. Count how many extra skills a trust-inclusive scan
      # would surface and, when there are any, note it with the trust command so
      # the omission is visible and actionable rather than silent.
      def warn_untrusted_hidden_skills(shown)
        return if Skills::Registry.project_local_trusted?

        all = Skills::Registry.new(include_project_local: true).all
        hidden = all.map(&:name) - shown.map(&:name)
        return if hidden.empty?

        root = Rubino::Workspace.primary_root
        Rubino.ui.warning(
          "#{hidden.size} project-local skill#{"s" if hidden.size != 1} hidden — " \
          "directory not trusted; start `rubino` here and accept the trust prompt for #{root} to load them"
        )
      rescue StandardError => e
        # The hint must never break `skills list` itself.
        Rubino.logger.warn(event: "skills.list_hint_failed", error: e.class.name, message: e.message)
        nil
      end

      # The Status cell: enabled/disabled from the StateRepository (the same
      # source the in-chat list's "(disabled)" marker reads), plus the active
      # pin when this process carries one (the slot is process-level, so a
      # fresh CLI run normally shows none — the marker matters in-process).
      def skill_status(name, registry)
        status = registry.enabled?(name) ? "enabled" : "disabled"
        status += " · active" if Rubino::ActiveSkill.current == name
        status
      end

      # The Source cell: where an installed skill came from (provenance ledger),
      # blank for built-in / hand-written skills.
      def provenance(name, sources)
        entry = sources[name]
        entry ? "#{entry["source"]} @ #{entry["commit"].to_s[0, 7]}" : ""
      end

      def toggle(name, enabled:)
        Rubino.ensure_database_ready!
        registry = Skills::Registry.trusted
        unless Skills::Toggle.set(name, enabled: enabled, registry: registry)
          # Unknown-skill toggle is a FAILURE (P2-H1/H2): list the available
          # names on stderr (Thor::Shell#say with :stderr) for the hint, then
          # raise so the run exits non-zero with the error on stderr too.
          available = registry.names
          warn "Available: #{available.join(", ")}" unless available.empty?
          raise Thor::Error, "unknown skill: #{name}"
        end

        Rubino.ui.success("#{enabled ? "Enabled" : "Disabled"} skill: #{name}")
      end

      # Resolves which of the discovered skills to install: explicit --skill
      # names (all-or-nothing — a typo aborts rather than half-installing),
      # --all, the only skill found, or an interactive pick. Off a TTY the
      # picker returns nil and the multi-skill case degrades to the catalogue
      # plus a --skill/--all hint.
      def install_selected(installer, found, wanted, checkout:, source:, commit:)
        chosen =
          if wanted.any?
            missing = wanted - found.map { |e| e[:name] }
            unless missing.empty?
              # Requested skill name(s) absent from the source: a FAILURE
              # (P2-H1/H2). Available list on stderr, then raise so exit != 0.
              warn "Available: #{found.map { |e| e[:name] }.join(", ")}"
              raise Thor::Error, "not found in #{source}: #{missing.join(", ")}"
            end
            found.select { |e| wanted.include?(e[:name]) }
          elsif options[:all] || found.size == 1
            found
          else
            pick_one(found)
          end
        return if chosen.nil?

        installer.install(chosen, checkout: checkout, source: source, commit: commit)
        chosen.each { |e| Rubino.ui.success("Installed skill: #{e[:name]} (#{source} @ #{commit[0, 7]})") }
        Rubino.ui.status("Installed into #{installer.skills_dir}")
      end

      # Multiple skills, none selected: print the catalogue and ask to pick
      # (the same arrow-key picker /sessions resume uses). nil when there is
      # no real terminal or the pick is cancelled.
      def pick_one(found)
        discovered_table(found)
        picked = Rubino.ui.select("Install which skill?", found.map { |e| [e[:name], e] })
        if picked.nil?
          Rubino.ui.info("Multiple skills found — pass --skill NAME (repeatable) or --all.")
          return nil
        end

        [picked]
      end

      def discovered_table(found)
        rows = found.map { |e| [e[:name], e[:path], e[:description]] }
        Rubino.ui.table(headers: %w[Name Path Description], rows: rows)
      end
    end
  end
end
