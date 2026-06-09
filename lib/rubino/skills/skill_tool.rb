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
      # kebab-case, <=64 chars, mirrors the skill-creator frontmatter contract.
      NAME_RE = /\A[a-z0-9]+(?:-[a-z0-9]+)*\z/

      def initialize(registry: nil)
        @registry = registry || Registry.new
      end

      def name
        "skill"
      end

      def description
        "Load a specialized skill's instructions into context, or create a new " \
          "skill. action defaults to \"load\": use it when a task matches one of " \
          "the available skills listed under \"## Skills\" in the system prompt " \
          "(pass file_path to load a bundled file). After finishing a complex, " \
          "multi-step task (typically 5+ tool calls) that is likely to recur and " \
          "isn't already covered, call action: \"create\" with name, description, " \
          "and body to save it as a reusable skill."
      end

      def input_schema
        {
          type: "object",
          properties: {
            action: {
              type: "string",
              enum: %w[load create],
              description: "\"load\" (default) loads an existing skill; " \
                           "\"create\" writes a new skill from name/description/body."
            },
            name: {
              type: "string",
              description: "The skill name. For load: the skill to load. " \
                           "For create: a kebab-case name (<=64 chars)."
            },
            file_path: {
              type: "string",
              description: "Optional (load only). Relative path of a bundled file within the " \
                           "skill (e.g. 'references/api.md', 'scripts/run.py') to load " \
                           "its contents. Use the linked_files listed when the skill " \
                           "body is first loaded."
            },
            description: {
              type: "string",
              description: "Required for create. One line: what the skill is for and WHEN " \
                           "it applies (the only text future runs see before loading it)."
            },
            body: {
              type: "string",
              description: "Required for create. The markdown body: proven step-by-step " \
                           "instructions, commands, and pitfalls. Be specific and prescriptive."
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
        return create(arguments) if action == "create"

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
        unless skill_name.match?(NAME_RE) && skill_name.length <= 64
          return "Cannot create skill: name must be kebab-case (lowercase letters, " \
                 "digits, hyphens) and <=64 chars; got #{skill_name.inspect}."
        end
        return "Cannot create skill: description is required." if description.empty?
        return "Cannot create skill: description must be <=1024 chars." if description.length > 1024
        return "Cannot create skill: body is required." if body.strip.empty?

        nil
      end

      def write_skill(skill_name, description, body)
        dir = File.join(skills_write_dir, skill_name)
        FileUtils.mkdir_p(dir)
        path = File.join(dir, "SKILL.md")
        content = "---\nname: #{skill_name}\ndescription: #{yaml_scalar(description)}\n---\n\n"
        content << body
        content << "\n" unless content.end_with?("\n")
        File.write(path, content)
        path
      end

      # Quote the description so a colon/newline can't break the YAML frontmatter.
      def yaml_scalar(text)
        one_line = text.tr("\n", " ").strip
        %("#{one_line.gsub('"', '\\"')}")
      end

      # First configured skills path (project-local .rubino/skills by
      # default) — the same source the Registry discovers from, so a created
      # skill is found on the immediate re-discover.
      def skills_write_dir
        dir = (Rubino.configuration.dig("skills", "paths") || [".rubino/skills"]).first
        File.expand_path(dir.to_s)
      end

      def duplicate(skill_name)
        "A skill named '#{skill_name}' already exists; not overwriting. " \
          "Pick a different name or load the existing one with skill(name: \"#{skill_name}\")."
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
