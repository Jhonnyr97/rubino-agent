# frozen_string_literal: true

module Rubino
  module LLM
    # Maps a user-supplied prompt to a fake scenario name using a keyword
    # router ported verbatim from the reference fake-provider SCENARIO_ROUTER.
    # The ordering of the rules is
    # significant — see the notes block in fake-provider-spec.md before
    # touching anything here.
    class ScenarioSelector
      ROUTER = [
        { keywords: ["simula quota exceeded", "quota exceeded", "provider quota"],
          scenario: "provider-quota-completed" },

        { keywords: ["cron fail", "cron failure", "cron error", "broken cron",
                     "failing cron", "fallisce cron", "cron fallisce"],
          scenario: "agent-creates-cron-failure" },

        { keywords: ["crea cron", "create cron", "create a cron", "cron job",
                     "scheduled task", "schedula", "pianifica",
                     "schedule daily", "schedule every", "schedule a daily",
                     "schedule a weekly", "daily cron", "weekly cron",
                     "every minute cron", "cron giornaliero", "report giornaliero",
                     "with-cron-success"],
          scenario: "agent-creates-cron" },

        { keywords: ["approve", "approval", "autorizza", "conferma", "permit", "allow"],
          scenario: "with-approvals" },

        { keywords: ["artifact", "generate report", "create file", "crea file",
                     "genera report", "write file", "save as"],
          scenario: "with-artifacts" },

        { keywords: ["upload", "allegato", "allega", "attached file",
                     "read this file", "analizza file"],
          scenario: "with-uploads" },

        { keywords: ["fail", "error", "errore", "fallito", "broken", "crash", "crash"],
          scenario: "failure" },

        { keywords: ["complex-analysis", "report", "analysis report", "comprehensive",
                     "full refactor", "refactoring completo", "multi-tool",
                     "multi step analysis"],
          scenario: "complex-analysis" },

        { keywords: ["multi-step", "analizza", "analyze", "refactor", "debug",
                     "investigate", "ricerca", "search", "trova",
                     "how would you", "what do you think"],
          scenario: "with-reasoning" },

        { keywords: ["analisi", "analysis", "spiegami", "explain in detail",
                     "descrivi l'architettura", "tell me about",
                     "how does it work", "full breakdown"],
          scenario: "analysis" },

        { keywords: ["which approach", "which option", "what do you think",
                     "choose between", "help me decide", "clarify",
                     "non so quale", "quale scegliere", "aiutami a scegliere"],
          scenario: "with-clarify" }
      ].freeze

      # Resolves the input text to a scenario name. First keyword match wins;
      # `default:` is returned when nothing matches. Matching is case-insensitive
      # on both the input and the keyword list. Blank/nil input → default.
      def self.resolve(input_text, default: "happy-path")
        return default if input_text.nil?

        text = input_text.to_s.downcase
        return default if text.strip.empty?

        ROUTER.each do |rule|
          rule[:keywords].each do |kw|
            return rule[:scenario] if text.include?(kw.downcase)
          end
        end
        default
      end
    end
  end
end
