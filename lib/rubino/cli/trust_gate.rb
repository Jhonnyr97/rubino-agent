# frozen_string_literal: true

module Rubino
  module CLI
    # The interactive folder-trust checkpoint. Asks ONCE per directory, before
    # that directory's AGENTS.md / project context + .rubino/skills are honored,
    # and remembers the answer in Rubino::Trust so it's never re-asked.
    #
    # Modelled on VS Code Workspace Trust + Claude Code's trust dialog. Declining
    # is non-destructive (VS Code "Restricted Mode"): the session still runs, it
    # just runs WITHOUT that directory's project context/skills (the assembler
    # consults Rubino::Trust.trusted? before injecting them).
    #
    # Skipped entirely — no prompt, treated as allowed for the duration — when:
    #   - the dir is already trusted,
    #   - the dir has nothing to gate (no context file, no .rubino/skills),
    #   - --ignore-rules was passed (project context is off regardless), or
    #   - the run is non-interactive (-q / no TTY): we never block automation.
    class TrustGate
      # A directory is only worth a trust decision when it actually ships
      # something rubino auto-injects: a project-context file or a skills dir.
      # An empty scratch dir has nothing to gate — so nothing is withheld and
      # the "untrusted — context/skills withheld" label would be misleading.
      # Exposed at the class level so the /dirs and /status listings can tell
      # "user declined" (gateworthy + not trusted) from "nothing to trust here"
      # (not gateworthy) and word the line honestly.
      def self.gateworthy?(dir)
        Context::FileDiscovery.new(base_path: dir).discover_files.any? ||
          File.directory?(File.join(dir, Skills::PromptIndex::DEFAULT_SKILL_DIR))
      rescue StandardError
        false
      end

      def initialize(ui: nil, interactive: true, ignore_rules: false)
        @ui = ui || Rubino.ui
        @interactive = interactive
        @ignore_rules = ignore_rules
      end

      # Ensures +dir+ has a trust decision. Returns true when the directory's
      # project context/skills may be loaded, false when it must run in
      # restricted mode. Prompts at most once, then remembers a "yes".
      def ensure_trust(dir)
        return true if Rubino::Trust.trusted?(dir)
        return true if @ignore_rules            # context already suppressed
        return true unless gateworthy?(dir)     # nothing to gate → no ceremony

        # Non-interactive: never block. We also do NOT remember it (the user
        # never vouched), so context stays withheld this run — Restricted Mode
        # by default for automation, matching VS Code's headless behaviour.
        return false unless @interactive

        prompt(dir)
      end

      private

      # Asks the one-time question and records the answer. Default is No.
      def prompt(dir)
        @ui.blank_line if @ui.respond_to?(:blank_line)
        @ui.info("▸ Starting in #{dir} — its AGENTS.md and project skills will shape the agent.")
        answer = @ui.ask("  Trust this folder? [y/N] ").to_s.strip.downcase

        if answer.start_with?("y")
          Rubino::Trust.remember(dir)
          @ui.success("Trusted #{dir} — loading its project context and skills.") if @ui.respond_to?(:success)
          true
        else
          @ui.info("Running in restricted mode — #{dir}'s AGENTS.md and skills will NOT be loaded.")
          false
        end
      end

      # See TrustGate.gateworthy? — instance delegate kept for the gate flow.
      def gateworthy?(dir)
        self.class.gateworthy?(dir)
      end
    end
  end
end
