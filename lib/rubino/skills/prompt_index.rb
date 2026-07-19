# frozen_string_literal: true

module Rubino
  module Skills
    # Builds the "## Skills (mandatory)" block injected into the SYSTEM PROMPT.
    #
    # This is the load-bearing trigger for skill auto-activation: surfacing the
    # skill catalogue inside the system prompt (not just the `skill` tool's
    # description) is what makes the model proactively scan and load a relevant
    # skill before replying. Mirrors the reference build_skills_system_prompt,
    # adapted to rubino's `skill(name)`
    # invocation and flat name+description catalogue.
    #
    # Always renders a block when the skills feature is on (the caller gates on
    # that): the catalogue half is dropped when no skills exist, but the
    # CREATION half is always present so even a fresh install with zero skills
    # nudges the agent to distill repeatable work into a new skill. Never
    # returns nil — an empty registry is a valid state that still wants the
    # create nudge.
    class PromptIndex
      # Where a freshly authored skill should be written. Mirrors the Registry's
      # project-local default path; surfaced in the create nudge so the agent
      # knows the exact destination + filename contract.
      DEFAULT_SKILL_DIR = ".rubino/skills"

      def initialize(registry: nil, active_tools: nil)
        @registry = registry || Registry.new
        @active_tools = active_tools
      end

      # Renders the "## Skills (mandatory)" block: the available-skills
      # catalogue (when any exist) followed by the proactive-creation nudge
      # (always). Never nil — see the class comment.
      def render
        [catalogue, creation_nudge].compact.join("\n\n")
      end

      private

      # The load-bearing auto-LOAD trigger. Nil when no skills are discovered,
      # so a fresh install shows only the create nudge instead of an empty
      # <available_skills> block.
      # Groups skills by category (P2: deterministic grouping — pure string
      # assembly, no LLM). Sorted by category name, then by skill name within
      # each category.
      def catalogue
        skills = @registry.catalog(active_tools: @active_tools)
        return nil if skills.empty?

        grouped = skills.group_by(&:category)
        lines = grouped.keys.sort.flat_map do |cat|
          group_lines = ["  #{cat}:"]
          grouped[cat].sort_by(&:name).each do |s|
            group_lines << "    - #{s.summary}"
          end
          group_lines
        end
        <<~PROMPT.strip
          ## Skills (mandatory)
          The skill catalogue below is the FIRST thing to consult on every task — read it before you plan or act. If a skill matches or is even partially relevant, you MUST load it with skill(name) and follow its instructions BEFORE answering. When unsure, load it: missing a skill's steps, pitfalls, or required conventions is far worse than loading one you didn't need. Skills carry specialized knowledge — APIs, tool-specific commands, and proven workflows that outperform general-purpose approaches — and the user's required conventions and quality standards, so load the matching skill even for tasks you already know how to do, because the skill defines how it must be done here.

          <available_skills>
          #{lines.join("\n")}
          </available_skills>

          Proceed without loading only if genuinely no skill is relevant to the task.
        PROMPT
      end

      # The proactive-CREATION nudge — the counterpart to the load trigger.
      # Without this the agent only ever consumes skills and never authors one,
      # so a completed complex/repeatable task is lost instead of distilled into
      # a reusable skill (skill-bench: proactive-creation F1 = 0). Gives the
      # exact path + SKILL.md format so the agent can write the file with its
      # normal file-writing tool, unprompted.
      #
      # Heads the block with the "## Skills" header when the catalogue is absent
      # (fresh install) so the header is never orphaned.
      def creation_nudge
        header = @registry.catalog.empty? ? "## Skills\n" : ""
        <<~PROMPT.strip
          #{header}### Creating skills
          When you finish a task that was complex, multi-step (typically 5+ tool calls), and likely to recur — and no existing skill already covers it — proactively capture it as a new skill so the next run is faster and more reliable. Do this at the natural end of the work, without being asked, and without interrupting the user mid-task. If the work was trivial, one-off, or already covered by a loaded skill, do NOT create one.

          Before you write or edit a skill, load the `skill-authoring` skill and follow it. Two rules matter as much as a trigger-focused description, because the skill hard-codes a choice for every future run: (1) prescribe a RELIABLE method — never enshrine a tool that can exit 0 while producing garbage; if one is known to fail silently, say so and prescribe the robust alternative; (2) END the procedure with a mandatory output-verification step that checks the result is actually correct (page/row count, re-open/parse, sanity assert) and NEVER trusts a tool's exit code or "Done".

          To create a skill, call the `skill` tool with action "create":

          <skill_create>
          skill(action: "create", name: "<kebab-case-name>", description: "Use when <trigger-class> — describe the TRIGGER that makes this skill relevant, not the task it performs. This is the only text future runs see before they decide to load the skill, so a trigger-focused description is better than a task label.", body: "# <Title>\\n\\n## When to use\\n- Bulleted triggers that warrant loading this skill.\\n- Also include counter-triggers: \\"Don't use for:\\"\\n\\nThe proven, step-by-step instructions, commands, and pitfalls you just worked out. Be specific and prescriptive.")
          </skill_create>

          This writes `#{DEFAULT_SKILL_DIR}/<name>/SKILL.md` for you with valid frontmatter — you do not need the write/edit tool for this.
        PROMPT
      end
    end
  end
end
