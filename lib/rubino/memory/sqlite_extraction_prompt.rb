# frozen_string_literal: true

module Rubino
  module Memory
    # The single aux-LLM extraction prompt for the Sqlite backend. Collapses
    # Zep's six-step ingestion (entity/fact/temporal extraction + invalidation)
    # into ONE structured call: given the latest turn and the currently-live
    # facts, the model returns durable atomic facts to `add` and contradicted
    # facts to `supersede`. The doctrine ("durable declarative facts, not
    # imperatives, not stale artifacts") is lifted from the reference MEMORY_GUIDANCE.
    module SqliteExtractionPrompt
      KINDS = %w[user_profile preference project fact env].freeze

      SYSTEM = <<~PROMPT
        You maintain a long-term memory of durable facts about the user and their project.
        You will see the latest conversation turn and the facts already in memory.

        Extract only DURABLE facts worth remembering across sessions:
          - user identity, preferences, and recurring corrections (highest value — they reduce future steering)
          - stable project/environment conventions and tool quirks
        Write each as ONE atomic declarative fact in the third person, present tense.
          GOOD: "User prefers concise answers without preamble."
          GOOD: "Project uses pytest with the xdist plugin."
          BAD (imperative): "Always answer concisely."        BAD (procedure): "Run tests with pytest -n 4."
          BAD (stale artifact): "Fixed bug #4821."  "Opened PR 90."  "Phase 2 done."
        If a fact will be stale within a week (PR/issue/commit numbers, task progress, TODO state), DO NOT save it.
        Procedures and how-to workflows are NOT memory — skip them.

        SALIENCE — most turns store NOTHING. Only save when the user asserted
        something durable about themselves, their preferences, or their project.
        Return {"add": [], "supersede": [], "edges": []} for trivial turns:
          - greetings / acknowledgements / one-word input ("hi", "help", "thanks", "ok")
          - throwaway Q&A and chit-chat with no durable assertion
          - transient task chatter about THIS session's work — e.g.
            "User decided to remove the mode feature.",
            "User asked for a test file named test_stats.py.",
            "Project has a stats.py with a main()." (in-the-moment task state, not a convention)
        When unsure whether something is durable enough to matter next week, DO NOT save it.

        SUPERSEDE: if a new fact CONTRADICTS an existing one (same subject, changed value),
        emit it under "supersede" with the id of the fact it replaces. Prefer the newer information.
        Tag each fact with 1-4 lowercase entity keywords (people, tools, projects) for retrieval.

        EDGES (optional, light): if the turn states a clear RELATIONSHIP between two of the
        entities you tagged, emit it under "edges" as {"src","relation","dst"} with a short
        lowercase relation (e.g. uses, deploys_to, written_in, runs_on, depends_on). Keep it to
        the few obvious relations the turn actually asserts — do not invent links. These let a
        later query like "what does X use for Y" reach the connected fact. Omit when unsure.

        Return STRICT JSON, no prose:
        { "add":       [ {"text": "...", "kind": "preference|user_profile|project|fact|env",
                          "entities": ["..."], "valid_from": "<ISO8601 or null>"} ],
          "supersede": [ {"id": "<existing fact id>", "by_text": "...", "kind": "...",
                          "entities": ["..."]} ],
          "edges":     [ {"src": "...", "relation": "...", "dst": "..."} ] }
        If nothing is worth saving, return {"add": [], "supersede": [], "edges": []}.
      PROMPT

      module_function

      # Builds the USER message: reference timestamp, the live fact set (already
      # char-capped by the caller), and the latest turn rendered as a transcript.
      def user_message(now:, live_facts:, turn:)
        live = if live_facts.empty?
                 "(none)"
               else
                 live_facts.map { |f| "#{f[:id]} | #{f[:kind]} | #{f[:text]}" }.join("\n")
               end

        <<~MSG
          Reference timestamp: #{now}
          Existing live facts:
          #{live}

          Latest turn:
          #{turn}
        MSG
      end
    end
  end
end
