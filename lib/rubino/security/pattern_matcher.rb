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
      ACTIONS = %w[allow ask deny].freeze

      def initialize(rules: {})
        @rules = parse_rules(rules)
      end

      # Returns the action for a given tool call description
      # Returns :allow, :ask, or :deny
      def match(tool_name, command_or_args = nil)
        full_string = [tool_name, command_or_args].compact.join(" ")

        # Check rules from most specific to least specific
        @rules.each do |pattern, action|
          return action.to_sym if matches_pattern?(full_string, pattern)
        end

        # Default: no explicit match
        nil
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
