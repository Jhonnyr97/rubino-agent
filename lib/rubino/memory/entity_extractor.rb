# frozen_string_literal: true

module Rubino
  module Memory
    # Deterministic, zero-dependency entity extraction for the graph-lite layer
    # (option 1). No LLM call, no Python/NER model — a pure-Ruby heuristic over a
    # fact's text that surfaces the proper-noun / identifier "entities" the
    # co_occurs graph connects. This is deliberately cheap (sub-ms) "optional
    # polish": the industry numbers show a graph adds only ~1.5pp to personal
    # agent-memory recall, so it must cost effectively nothing to build.
    #
    # It catches three shapes that reliably name things in dev/agent facts:
    #   1. hyphen/underscore identifiers ...... rubino-agent, deepseek-v4-pro
    #   2. internal-caps / acronyms ........... AziendaOS, RSpec, GLiNER, API
    #   3. plain capitalized proper nouns ..... Incus, Kamal, Nilthon, Rails
    # then drops a stopword set (sentence-initial common words, pronouns, generic
    # verbs/nouns) so "Please", "User", "Based", "Remember" don't become nodes.
    module EntityExtractor
      module_function

      MAX_ENTITIES = 12

      # shape 1: token with an internal - or _ join (identifier-like)
      IDENTIFIER = /\b[A-Za-z][A-Za-z0-9]*(?:[-_][A-Za-z0-9]+)+\b/
      # shape 2: has an interior capital OR is an all-caps run of 2+ (acronym)
      INTERNAL_CAPS = /\b[A-Za-z][a-z0-9]*[A-Z][A-Za-z0-9]*\b/
      ACRONYM = /\b[A-Z]{2,}[A-Za-z0-9]*\b/
      # shape 3: a plain Capitalized word (proper-noun candidate), 3+ letters
      CAPITALIZED = /\b[A-Z][a-z]{2,}\b/

      # Common capitalized-at-sentence-start / generic words that are NOT entities.
      STOPWORDS = %w[
        the this that these those there here then than when where what which who whom whose why how
        and but for nor yet with from into onto over under about above below between within without
        you your yours our ours their theirs his her hers its
        also please remember note based using used uses use user users project projects memory memories
        fact facts prefer prefers preferred work works working deploy deploys deployed deployment
        name names called call calls run runs running make makes made set sets setting get gets
        add adds added store stores stored save saves saved keep keeps kept want wants need needs
        should would could will shall may might must can cannot does doing done have has had
        always never often usually sometimes strongly really very much more most less least
        one two three first second next last new old good bad best worst same other another
        today tomorrow yesterday now later before after during while because since until
        code coding agent agents tool tools test tests testing thing things way ways
      ].to_set.freeze

      # Returns a deduped, bounded list of entity name strings from `text`.
      def extract(text)
        s = text.to_s
        return [] if s.strip.empty?

        seen = {}
        [IDENTIFIER, INTERNAL_CAPS, ACRONYM, CAPITALIZED].each do |re|
          s.scan(re) do |tok|
            name = tok.strip
            next if name.length < 2
            norm = name.downcase
            next if STOPWORDS.include?(norm)
            # keep the first-seen surface form for a given normalized name
            seen[norm] ||= name
          end
        end
        seen.values.first(MAX_ENTITIES)
      end
    end
  end
end
