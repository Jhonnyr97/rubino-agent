# frozen_string_literal: true

module Rubino
  module Memory
    # Salience pre-filter for the auto-extraction path (r5 F5/F6/F7).
    #
    # The aux-LLM extraction prompt already asks the model to emit nothing
    # ({"add":[],"supersede":[]}) for trivial turns, but in practice it still
    # mints facts from greetings, a one-word "help", and transient task chatter
    # ("User decided to remove the mode feature"). Following Claude Code's
    # auto-memory ("decides what's worth remembering for a FUTURE conversation"),
    # mem0's NOOP path, and Letta's "save only durable facts", this is a cheap
    # heuristic NOOP gate that runs BEFORE the aux call: if a turn's USER text
    # carries no plausibly-durable assertion, skip the extraction entirely. That
    # both saves the aux spend and guarantees no fact is minted from throwaway
    # input — the model never gets a chance to over-extract.
    #
    # Deliberately conservative: it only suppresses turns that are *clearly*
    # non-durable (greetings/acknowledgements, bare command words, very short
    # throwaway Q&A with no first-person assertion). Anything with a first-person
    # statement, a preference/decision verb, or substantive length passes through
    # to the aux model, which remains the real salience judge (and applies the
    # durable-vs-stale doctrine in its prompt). False negatives here only cost a
    # redundant aux call; they never store a bad fact.
    module SalienceGate
      module_function

      # Single bare words / short interjections that are never durable on their
      # own — slash-less command reflexes and greetings a sloppy user fires.
      TRIVIAL_WORDS = %w[
        help commands ? h hi hey hello yo sup yes no ok okay yeah yep nope nah
        thanks thank ty thx please cool nice great done quit exit bye q :q :wq
        continue go next stop wait what why how when who
      ].to_set.freeze

      # First-person / assertion signals that mark a turn as plausibly carrying a
      # durable fact, preference, or correction worth the aux model's attention.
      # Kept broad on purpose — the aux model is the precise judge; this only
      # decides whether it's worth ASKING it.
      DURABLE_SIGNALS = [
        /\bmy name is\b/i,
        /\bi(?:'m| am)\b/i,
        /\bi (?:prefer|like|love|hate|want|need|use|always|never|usually|work|deploy|run|don't|do not)\b/i,
        /\bwe (?:use|prefer|decided|always|never|deploy|run|agreed)\b/i,
        /\bcall me\b/i,
        /\b(?:please )?(?:always|never|don't ever|do not ever) (?:use|do|run|call|assume)\b/i,
        /\bremember (?:that|this|:)/i,
        /\bthe (?:project|repo|codebase|team|convention|standard) (?:uses|is|prefers|requires)\b/i
      ].freeze

      # Decide whether the turn's transcript is worth feeding the aux extractor.
      # `turn_text` is the rendered USER/ASSISTANT transcript the backend already
      # builds. Returns true when the turn MAY carry durable info (let the aux
      # model decide), false to NOOP immediately.
      def salient?(turn_text)
        user = user_lines(turn_text)
        # No user text at all (e.g. an assistant-only turn) → nothing the user
        # asserted to remember.
        return false if user.empty?

        joined = user.join(" ").strip
        return true if DURABLE_SIGNALS.any? { |re| joined.match?(re) }

        # Strip the USER text to its informative core. A turn that is only
        # greetings/acknowledgements/bare command words once normalized has no
        # durable assertion to mine.
        meaningful = informative_words(joined)
        return false if meaningful.empty?

        # Very short throwaway turns with no durable signal (a one-word "help", a
        # bare "thanks", "what is this") aren't worth an extraction pass. A turn
        # only clears the bar once it has a few content words — long enough to
        # plausibly state something durable. The aux model still vets it.
        meaningful.size >= MIN_CONTENT_WORDS
      end

      # A turn shorter than this (in informative words, after dropping trivial/
      # stopword tokens) and lacking any explicit durable signal is treated as
      # throwaway. 3 lets "I use Kamal" through (signal-matched anyway) while
      # dropping "help", "thanks", "what now".
      MIN_CONTENT_WORDS = 3

      # USER-role lines from the rendered transcript (the backend prefixes each
      # line with "USER: " / "ASSISTANT: "). We gate on what the user actually
      # said, not on the assistant's narration (which is where transient
      # "User decided to remove X" task-chatter leaks in).
      def user_lines(turn_text)
        turn_text.to_s.lines.filter_map do |line|
          m = line.match(/\AUSER:\s?(.*)\z/m)
          m && m[1].strip
        end.reject(&:empty?)
      end

      # Lowercase content words with trivial command/greeting tokens and pure
      # punctuation removed, used to measure throwaway-ness.
      def informative_words(text)
        text.downcase.scan(/[\p{L}\p{N}']+/).reject do |w|
          TRIVIAL_WORDS.include?(w)
        end
      end
    end
  end
end
