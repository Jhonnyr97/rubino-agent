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

      def initialize(registry: nil)
        @registry = registry || Registry.new
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
      def catalogue
        summaries = @registry.summaries
        return nil if summaries.empty?

        lines = summaries.map { |s| "  - #{s}" }.join("\n")
        <<~PROMPT.strip
          ## Skills (mandatory)
          Before replying, scan the skills below. If a skill matches or is even partially relevant to your task, you MUST load it with skill(name) and follow its instructions. Err on the side of loading — it is always better to have context you don't need than to miss critical steps, pitfalls, or established workflows. Skills contain specialized knowledge — APIs, tool-specific commands, and proven workflows that outperform general-purpose approaches — and they encode the user's preferred conventions and quality standards. Load the relevant skill even for tasks you already know how to do, because the skill defines how it should be done here.

          <available_skills>
          #{lines}
          </available_skills>

          Only proceed without loading a skill if genuinely none are relevant to the task.
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
        header = @registry.summaries.empty? ? "## Skills\n" : ""
        <<~PROMPT.strip
          #{header}### Creating skills
          When you finish a task that was complex, multi-step (typically 5+ tool calls), and likely to recur — and no existing skill already covers it — proactively capture it as a new skill so the next run is faster and more reliable. Do this at the natural end of the work, without being asked, and without interrupting the user mid-task. If the work was trivial, one-off, or already covered by a loaded skill, do NOT create one.

          To create a skill, call the `skill` tool with action "create":

          <skill_create>
          skill(action: "create", name: "<kebab-case-name>", description: "One line saying what the skill is for and WHEN it applies — this is the only text future runs see before loading it, so make it match-on-sight.", body: "# <Title>\\n\\nThe proven, step-by-step instructions, commands, and pitfalls you just worked out. Be specific and prescriptive.")
          </skill_create>

          This writes `#{DEFAULT_SKILL_DIR}/<name>/SKILL.md` for you with valid frontmatter — you do not need the write/edit tool for this.
        PROMPT
      end
    end
  end
end
