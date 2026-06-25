# frozen_string_literal: true

module Rubino
  module Security
    # Pattern-based permission matcher supporting wildcards.
    # Matches tool names, commands, and file paths against configured rules.
    #
    # Rules format in config:
    #   permissions:
    #     "git *": "allow"
    #     "shell rm -rf *": "deny"
    #     "file_system write ~/.env": "deny"
    #     "shell bundle *": "allow"
    #
    # Actions: "allow", "ask", "deny"
    class PatternMatcher
      def initialize(rules: {})
        @rules = parse_rules(rules)
      end

      # Returns the action for a given tool call description
      # Returns :allow, :ask, or :deny (nil when no rule matches).
      #
      # DENY ALWAYS WINS (the documented permissions invariant). Resolution is
      # NOT a plain first-hit on the specificity-sorted list — that let a longer,
      # more specific :allow outrank a shorter overlapping :deny (e.g.
      # "shell git push" => deny vs. "shell git push --force-with-lease …" =>
      # allow), silently swallowing the deny. Instead we resolve in two passes
      # over ALL matching rules:
      #
      #   1. If ANY matching rule is :deny, the result is :deny — regardless of
      #      a longer overlapping :allow/:ask. (deny wins ACROSS verdict classes)
      #   2. Otherwise the FIRST (= longest/most-specific, per #parse_rules)
      #      matching :allow/:ask wins. (longest-match preserved WITHIN a class)
      #
      # The hardline floor is a separate, earlier layer (ApprovalPolicy step 1)
      # and is unaffected.
      def match(tool_name, command_or_args = nil)
        full_string = [tool_name, command_or_args].compact.join(" ")

        first_non_deny = nil
        @rules.each do |pattern, action|
          next unless matches_pattern?(full_string, pattern)

          sym = action.to_sym
          # Pass 1: a deny short-circuits everything — deny always wins.
          return :deny if sym == :deny

          # Pass 2 (deferred): remember the first (most-specific) allow/ask, but
          # keep scanning in case a shorter overlapping deny is still ahead.
          first_non_deny ||= sym
        end

        # No matching deny: the longest/most-specific allow/ask (or nil).
        first_non_deny
      end

      # Returns true if the pattern matches the input
      def matches_pattern?(input, pattern)
        # Convert glob-style pattern to regex
        regex_str = Regexp.escape(pattern)
                          .gsub('\*', ".*")
                          .gsub('\?', ".")
        regex = Regexp.new("\\A#{regex_str}\\z", Regexp::IGNORECASE)
        input.match?(regex)
      end

      private

      def parse_rules(rules)
        return {} unless rules.is_a?(Hash)

        # Sort by specificity: more specific patterns first
        # (longer patterns without wildcards are more specific)
        rules.sort_by do |pattern, _|
          specificity = pattern.length
          specificity -= 10 if pattern.include?("*")
          -specificity
        end.to_h
      end
    end
  end
end
