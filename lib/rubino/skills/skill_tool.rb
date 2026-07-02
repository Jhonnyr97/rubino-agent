# frozen_string_literal: true

require "fileutils"

module Rubino
  module Skills
    # Tool that allows the agent to load a skill on demand, and (Variant A —
    # reference-style affordance) to CREATE a new skill inline during the turn.
    #
    # The agent sees skill names/descriptions in the system prompt and can invoke
    # this tool to load the full skill instructions into context, or — after a
    # complex, repeatable task — to distil what it just did into a new skill with
    # action: "create" (0 extra LLM calls; the create happens inline on the
    # tool-call the model already emitted).
    class SkillTool < Tools::Base
      # Subdirs a supporting file (write_file) may live under (mirrors Hermes).
      SUPPORT_DIRS = %w[references templates scripts assets].freeze

      def initialize(registry: nil)
        @registry = registry || Registry.new
      end

      def name
        "skill"
      end

      def description
        "Load a specialized skill's instructions into context, or author/maintain " \
          "skills. action defaults to \"load\": use it when a task matches one of the " \
          "available skills listed under \"## Skills\" in the system prompt (pass " \
          "file_path to load a bundled file). After finishing a complex, multi-step " \
          "task (typically 5+ tool calls) likely to recur, either UPDATE an existing " \
          "skill it fits (action \"edit\"/\"patch\", or \"write_file\" for a support " \
          "file) or, if none covers it, action \"create\" a new one with " \
          "name/description/body."
      end

      def input_schema # rubocop:disable Metrics/MethodLength -- flat JSON-schema literal
        {
          type: "object",
          properties: {
            action: {
              type: "string",
              enum: %w[load create edit patch write_file],
              description: "\"load\" (default) loads an existing skill; \"create\" writes a " \
                           "new skill from name/description/body; \"edit\" rewrites an existing " \
                           "skill's SKILL.md body; \"patch\" does a find-and-replace in SKILL.md " \
                           "or a bundled file (old_str/new_str); \"write_file\" adds a supporting " \
                           "file (references/templates/scripts/assets). Prefer edit/patch over " \
                           "create when an existing skill already covers the territory."
            },
            name: {
              type: "string",
              description: "The skill name. For load/edit/patch/write_file: the existing skill. " \
                           "For create: a kebab-case name (<=64 chars)."
            },
            file_path: {
              type: "string",
              description: "For load: relative path of a bundled file to read (e.g. " \
                           "'references/api.md'). For patch: the file to patch (defaults to " \
                           "SKILL.md). For write_file: the relative path to write under " \
                           "references/, templates/, scripts/, or assets/."
            },
            description: {
              type: "string",
              description: "Required for create (optional for edit — kept as-is if omitted). " \
                           "One line: what the skill is for and WHEN it applies."
            },
            body: {
              type: "string",
              description: "Required for create/edit. The markdown body: proven step-by-step " \
                           "instructions, commands, and pitfalls. Be specific and prescriptive."
            },
            old_str: {
              type: "string",
              description: "Required for patch. The exact text to replace; must occur once."
            },
            new_str: {
              type: "string",
              description: "For patch. The replacement text (empty string deletes old_str)."
            },
            content: {
              type: "string",
              description: "Required for write_file. The full contents of the supporting file."
            }
          },
          required: %w[name]
        }
      end

      def risk_level
        :low
      end

      # action: "load" (default) — three-level progressive disclosure:
      #   skill(name)                       -> Level 2: SKILL.md body
      #   skill(name, file_path: "ref.md")  -> Level 3: one bundled file
      # action: "create" — write a new <name>/SKILL.md inline (Variant A).
      def call(arguments)
        action = (arguments["action"] || arguments[:action] || "load").to_s
        case action
        when "create"     then return create(arguments)
        when "edit"       then return edit(arguments)
        when "patch"      then return patch(arguments)
        when "write_file" then return write_file(arguments)
        end

        skill_name = arguments["name"] || arguments[:name]
        file_path  = arguments["file_path"] || arguments[:file_path]

        skill = @registry.find(skill_name)
        return not_found(skill_name) unless skill
        return disabled(skill_name) unless @registry.enabled?(skill_name)

        return load_bundled_file(skill, skill_name, file_path) if file_path && !file_path.to_s.empty?

        load_body(skill, skill_name)
      end

      private

      # ---- create (Variant A: inline, 0 extra LLM calls) --------------------

      def create(arguments)
        skill_name  = (arguments["name"] || arguments[:name]).to_s.strip
        description = (arguments["description"] || arguments[:description]).to_s.strip
        body        = (arguments["body"] || arguments[:body]).to_s

        err = validate_create(skill_name, description, body)
        return err if err

        return duplicate(skill_name) if @registry.find(skill_name)

        path = write_skill(skill_name, description, body)
        # Re-discover so the new skill is immediately usable. The disk-diff in
        # Registry#discover! is the SINGLE source of truth for
        # skills_created_total — it books the just-written skill on this re-scan,
        # so we must NOT increment the counter inline here too (that would
        # double-count one creation).
        @registry.discover!
        Rubino.active_event_bus&.emit(
          Interaction::Events::SKILL_CREATED,
          name: skill_name, file_path: path
        )
        "Created skill '#{skill_name}' at #{path}. It is now available to load " \
          "with skill(name: \"#{skill_name}\")."
      rescue StandardError => e
        "Could not create skill '#{skill_name}': #{e.message}"
      end

      def validate_create(skill_name, description, body)
        return "Cannot create skill: name is required." if skill_name.empty?
        unless skill_name.match?(Skill::NAME_RE) && skill_name.length <= 64
          return "Cannot create skill: name must be kebab-case (lowercase letters, " \
                 "digits, hyphens) and <=64 chars; got #{skill_name.inspect}."
        end
        return "Cannot create skill: description is required." if description.empty?
        return "Cannot create skill: description must be <=1024 chars." if description.length > 1024
        return "Cannot create skill: body is required." if body.strip.empty?

        nil
      end

      def write_skill(skill_name, description, body)
        Skill.write!(dir: File.join(skills_write_dir, skill_name),
                     name: skill_name, description: description, body: body)
      end

      # The agent HOME skills dir — the SAME place Installer writes to and the
      # Registry discovers via its "~/.rubino/skills" entry. Authored skills go
      # to the user's home (RUBINO_HOME → else ~/.rubino), never the cwd, so a
      # skill created/distilled while cd'd into a repo can't leak into that
      # repo's working tree (SK-1). This also addresses SK-2 UNDER THE DEFAULT
      # config: the home dir lives outside the workspace, so the workspace
      # sandbox (`tools.workspace_strict`, default true) is the boundary that
      # blocks a plain `write`/`edit` to a SKILL.md there, leaving the #405-gated
      # skill(create) helper as the path in. This is SANDBOX-gated, NOT a
      # credential-floor guarantee: the always-on #413 write-floor covers only
      # credentials (.env/.sqlite3/oauth/.key/.pem), not skills (which aren't
      # credentials — keep them out of the floor). Disabling the sandbox
      # (workspace_strict=false) is an operator choice that removes this gate,
      # so a plain write CAN then overwrite a home SKILL.md.
      # Mirrors Hermes, which writes new skills under HERMES_HOME/skills.
      def skills_write_dir
        File.join(Config::Loader.default_home_path, "skills")
      end

      def duplicate(skill_name)
        "A skill named '#{skill_name}' already exists; not overwriting. " \
          "Pick a different name, or UPDATE it with action \"edit\"/\"patch\", " \
          "or load it with skill(name: \"#{skill_name}\")."
      end

      # ---- edit / patch / write_file (UPDATE existing HOME skills) -----------
      # Prefer these over create when a loaded/existing skill already covers the
      # territory (Hermes' update-over-create shape). They only touch skills
      # authored under the agent HOME dir; a bundled (gem-shipped) skill is
      # protected and refused.

      # Full SKILL.md body rewrite. Keeps the existing description unless a new
      # one is passed. Major overhauls only — prefer patch for small changes.
      def edit(arguments)
        name = str(arguments, "name")
        body = str(arguments, "body")
        skill, dir, err = editable(name)
        return err if err
        return "Cannot edit skill '#{name}': body is required." if body.empty?

        description = description_arg?(arguments) ? str(arguments, "description") : skill.description.to_s
        return "Cannot edit skill '#{name}': description must be <=1024 chars." if description.length > 1024

        path = Skill.write!(dir: dir, name: skill.name, description: description, body: body)
        @registry.discover!
        "Updated skill '#{skill.name}' (full SKILL.md rewrite) at #{path}."
      rescue StandardError => e
        "Could not edit skill '#{name}': #{e.message}"
      end

      # Targeted find-and-replace within SKILL.md (default) or a bundled file.
      # old_str must occur EXACTLY once so the edit is unambiguous.
      def patch(arguments)
        name    = str(arguments, "name")
        rel     = str(arguments, "file_path")
        old_str = raw(arguments, "old_str")
        new_str = raw(arguments, "new_str")
        skill, dir, err = editable(name)
        return err if err
        return "Cannot patch skill '#{name}': old_str is required." if old_str.empty?

        label  = rel.empty? ? "SKILL.md" : rel
        target = rel.empty? ? File.join(dir, "SKILL.md") : safe_join(dir, rel)
        return "Cannot patch skill '#{name}': file_path escapes the skill dir." unless target
        return "Cannot patch skill '#{name}': file '#{label}' not found." unless File.file?(target)

        content = File.read(target, encoding: "UTF-8")
        count   = content.scan(old_str).size
        return "Cannot patch skill '#{name}': old_str not found in #{label}." if count.zero?
        return "Cannot patch skill '#{name}': old_str matches #{count}× in #{label}; make it unique." if count > 1

        File.write(target, content.sub(old_str, new_str))
        @registry.discover!
        "Patched #{label} in skill '#{skill.name}'."
      rescue StandardError => e
        "Could not patch skill '#{name}': #{e.message}"
      end

      # Add/overwrite a supporting file under references/ templates/ scripts/
      # assets/ — session-specific detail, starter templates, or re-runnable
      # scripts, per Hermes' class-level-umbrella shape.
      def write_file(arguments)
        name    = str(arguments, "name")
        rel     = str(arguments, "file_path")
        content = raw(arguments, "content")
        skill, dir, err = editable(name)
        return err if err
        return "Cannot write file: file_path is required." if rel.empty?
        unless SUPPORT_DIRS.include?(rel.split("/").first)
          return "Cannot write file: supporting files must live under #{SUPPORT_DIRS.join("/, ")}/."
        end

        target = safe_join(dir, rel)
        return "Cannot write file: file_path escapes the skill dir." unless target

        FileUtils.mkdir_p(File.dirname(target))
        File.write(target, content)
        @registry.discover!
        "Wrote #{rel} in skill '#{skill.name}'."
      rescue StandardError => e
        "Could not write file in skill '#{name}': #{e.message}"
      end

      # [skill, dir, nil] when +name+ is an editable HOME directory-skill, else
      # [nil, nil, error]. Refuses unknown, flat-file, and protected bundled
      # skills (those whose dir is not under the agent HOME skills dir).
      def editable(name)
        name = name.to_s.strip
        return [nil, nil, "Cannot update skill: name is required."] if name.empty?

        skill = @registry.find(name)
        return [nil, nil, not_found(name)] unless skill
        return [nil, nil, "Skill '#{name}' is a flat-file skill and can't be updated in place."] unless skill.directory?

        dir = File.dirname(skill.path)
        unless under_home?(dir)
          return [nil, nil, "Skill '#{name}' is a bundled skill and is protected from edits. " \
                            "Create a new skill instead."]
        end
        [skill, dir, nil]
      end

      def under_home?(dir)
        home = File.expand_path(skills_write_dir)
        resolved = File.expand_path(dir)
        resolved == home || resolved.start_with?("#{home}#{File::SEPARATOR}")
      end

      # Resolve +rel+ within +dir+, refusing any path that escapes it.
      def safe_join(dir, rel)
        root   = File.expand_path(dir)
        target = File.expand_path(rel.to_s, root)
        return nil unless target == root || target.start_with?("#{root}#{File::SEPARATOR}")

        target
      end

      def description_arg?(arguments)
        arguments.key?("description") || arguments.key?(:description)
      end

      def str(arguments, key)
        (arguments[key] || arguments[key.to_sym]).to_s.strip
      end

      def raw(arguments, key)
        value = arguments[key]
        value = arguments[key.to_sym] if value.nil?
        value.to_s
      end

      # ---- load (unchanged) -------------------------------------------------

      def load_body(skill, skill_name)
        body = "Skill '#{skill_name}' loaded:\n\n#{skill.content}"
        body << linked_files_hint(skill, skill_name) unless skill.linked_files.empty?
        announce_loaded(skill_name)
        body
      end

      def announce_loaded(skill_name)
        Metrics.counter(:skills_loaded_total).increment
        Rubino.active_event_bus&.emit(
          Interaction::Events::SKILL_LOADED,
          name: skill_name
        )
      end

      def linked_files_hint(skill, skill_name)
        listing = skill.linked_files.map { |f| "  - #{f}" }.join("\n")
        "\n\nBundled files (load with skill(name: \"#{skill_name}\", file_path: \"...\")):\n#{listing}"
      end

      def load_bundled_file(skill, skill_name, file_path)
        contents = skill.read_file(file_path)
        if contents
          "Skill '#{skill_name}' file '#{file_path}':\n\n#{contents}"
        else
          available = skill.current_linked_files.join(", ")
          "File '#{file_path}' not found in skill '#{skill_name}'. " \
            "Available files: #{available.empty? ? "(none)" : available}"
        end
      end

      def not_found(skill_name)
        available = @registry.names.join(", ")
        "Skill '#{skill_name}' not found. Available skills: #{available}"
      end

      def disabled(skill_name)
        "Skill '#{skill_name}' is disabled."
      end
    end
  end
end
