# frozen_string_literal: true

module Rubino
  module Security
    # Derives the REUSABLE rule that an approval should be remembered as,
    # instead of pinning memory to the exact "<tool>:<command>" string.
    #
    # Mirrors the reference persistence unit: approve_session/is_approved key on a
    # PATTERN KEY, not the raw command.
    # For a dangerous command the pattern key IS the dangerous description, so
    # approving it once covers the whole risk class for the session. For a plain
    # command the reference allowlist is prefix-ish; we derive a leading-token prefix
    # the same way CommandAllowlist matches (start_with?, command_allowlist.rb).
    #
    # Pure derivation — no I/O, no persistence. Returns a small immutable Rule.
    #
    #   kind == :pattern  -> remember a dangerous-pattern CLASS  (value = key)
    #   kind == :prefix   -> remember a command PREFIX           (value = "git")
    #   kind == :command  -> remember one EXACT command          (value = "git status")
    module PrefixDeriver
      Rule = Struct.new(:kind, :value, keyword_init: true) do
        # Does this remembered rule cover `command`? Matching mirrors the
        # storage shape: a pattern covers any sibling of its class, a prefix
        # covers any command that start_with? it (like CommandAllowlist), an
        # exact command covers only itself.
        def covers?(command)
          cmd = command.to_s
          case kind
          when :pattern then DangerousPatterns.detect(cmd)[1] == value
          when :prefix  then cmd.strip.start_with?(value.to_s.strip)
          else               cmd.strip == value.to_s.strip
          end
        end
      end

      # Wrapper commands whose first sub-token is part of the meaningful
      # prefix ("bundle exec" / "npm run"), not the argument. Without this a
      # naive "first token" prefix would collapse `bundle exec rspec` and
      # `bundle install` into the same `bundle` rule.
      WRAPPERS = {
        "bundle" => %w[exec].freeze,
        "npm"    => %w[run].freeze,
        "yarn"   => %w[run].freeze,
        "pnpm"   => %w[run].freeze,
        "rake"   => [].freeze,
        "cargo"  => %w[run].freeze
      }.freeze

      module_function

      # Builds the rule a (tool, command) approval should be remembered as.
      #
      # @param pattern_key [String, nil] the dangerous description when the
      #   caller has already detected one; we re-detect when absent so callers
      #   that only have the raw command still get a :pattern rule.
      def rule_for(tool:, command:, pattern_key: nil)
        cmd = command.to_s
        key = pattern_key || DangerousPatterns.detect(cmd)[1]
        return Rule.new(kind: :pattern, value: key) if key

        # The :prefix rule ("allow `<head>` commands") only makes sense for the
        # shell tool, where sibling commands genuinely share a leading
        # executable (git status / git diff). For structured-arg tools the
        # "command" is a file path (write/edit/read) or a code/arg fragment
        # (ruby), so a derived prefix is nonsense — "allow `output.txt`
        # commands", "allow `6` commands". Remember those by exact command
        # instead, so the CLI/web offer no bogus prefix choice. (B6)
        return command_rule(tool: tool, command: cmd) unless tool.to_s == "shell"

        prefix = command_prefix(cmd)
        return command_rule(tool: tool, command: cmd) if prefix.empty?

        Rule.new(kind: :prefix, value: prefix)
      end

      # The NARROW rule used by :session / :always_command for S3 so behavior
      # stays stable: a dangerous command remembers its pattern class (matching
      # the reference), everything else remembers the exact command. The broad :prefix
      # rule is derivable via rule_for but only wired into a decision in S5.
      def narrow_rule_for(tool:, command:, pattern_key: nil)
        cmd = command.to_s
        key = pattern_key || DangerousPatterns.detect(cmd)[1]
        return Rule.new(kind: :pattern, value: key) if key

        command_rule(tool: tool, command: cmd)
      end

      def command_rule(tool:, command:)
        value = command.to_s.strip
        value = tool.to_s if value.empty?
        Rule.new(kind: :command, value: value)
      end

      # Leading safe-token run of a plain command:
      #   "git status"            -> "git"
      #   "bundle exec rspec"     -> "bundle exec"
      #   "npm run test --watch"  -> "npm run"
      # A plain command keeps only its head; a wrapper command (bundle/npm/...)
      # additionally keeps its declared verb (exec/run) so distinct wrapped
      # tools don't collapse into one rule. The run stops at the first flag or
      # argument-shaped token, mirroring CommandAllowlist's start_with? match.
      def command_prefix(command)
        tokens = command.to_s.strip.split(/\s+/)
        return "" if tokens.empty?

        head = tokens.first
        prefix = [head]

        if WRAPPERS.key?(head)
          verb = tokens[1]
          prefix << verb if verb && plain_word?(verb) && WRAPPERS[head].include?(verb)
        end

        prefix.join(" ")
      end

      # A "plain word" is a bare token: not a flag, no path/assignment/glob
      # punctuation — the shape that can safely extend a prefix.
      def plain_word?(token)
        token.match?(/\A[A-Za-z0-9_:.-]+\z/) && !token.start_with?("-")
      end
    end
  end
end
