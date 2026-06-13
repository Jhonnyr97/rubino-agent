# frozen_string_literal: true

require "shellwords"

module Rubino
  module Security
    # Manages a whitelist of shell commands that can be executed without
    # confirmation.
    #
    # An allowlist entry pre-approves an EXACT single command, never a prefix
    # of a larger compound line. A naive `start_with?` (the old behaviour) let
    # any line whose head matched an entry auto-resolve to :allow — INCLUDING
    # the chained tail: with `git status` allowlisted,
    # `git status; echo k >> ~/.ssh/authorized_keys` resolved to :allow,
    # turning a read-only pre-approval into headless RCE/exfil. So this matcher
    # is chain-aware, mirroring ReadonlyCommands:
    #
    #   - DangerousPatterns runs FIRST on the whole line, so a dangerous tail
    #     (curl|sh, recursive rm, write into ~/.ssh, ...) can never be beaten
    #     by an allowlisted head;
    #   - the line is split into chain segments (|, ||, &&, ;, newline) with the
    #     same quote-aware splitter as ReadonlyCommands, which REJECTS the line
    #     outright on redirection (>), backgrounding (&), command substitution
    #     ($(...) / backticks) or process substitution (<(...) / >()) — the
    #     constructs that smuggle a write or an execution past a head check;
    #   - EVERY segment must match an allowlist entry, and a match is on a TOKEN
    #     boundary (a prefix of token tokens), never a bare substring: `git`
    #     allowlisted does NOT pre-approve `git-secret-leak`, and `git status`
    #     does NOT pre-approve `git statusxyz`.
    class CommandAllowlist
      def initialize(config: nil)
        @config = config || Rubino.configuration
        @allowlist = @config.security_command_allowlist
      end

      # Returns true ONLY when the ENTIRE command line is covered by the
      # allowlist: not dangerous, splits cleanly into chain segments, and every
      # segment's head matches an allowlist entry on a token boundary.
      #
      # An EMPTY allowlist matches NOTHING — pre-approval is opt-in, so an
      # unconfigured allowlist must never auto-approve everything.
      def allowed?(command)
        return false if @allowlist.empty?
        return false if DangerousPatterns.dangerous?(command)

        entries = allowlist_token_lists
        return false if entries.empty?

        segments = ReadonlyCommands.split_segments(command.to_s)
        return false if segments.nil? || segments.empty?

        segments.all? { |segment| segment_allowed?(segment, entries) }
      end

      private

      # Each allowlist entry as its token list (e.g. "bundle exec rspec" ->
      # %w[bundle exec rspec]). Empty / blank entries are dropped so a stray ""
      # in the config can't match every command.
      def allowlist_token_lists
        @allowlist.filter_map do |entry|
          tokens = Shellwords.split(entry.to_s)
          tokens unless tokens.empty?
        rescue ArgumentError
          nil # an entry that won't tokenize (unbalanced quote) can't match
        end
      end

      # A single chain segment is allowed when its leading tokens exactly match
      # some allowlist entry's tokens. Matching on the token list (not the raw
      # string) makes it boundary-safe: `git status` matches `git status -s`
      # but never `git statusxyz`.
      def segment_allowed?(segment, entries)
        tokens = Shellwords.split(segment)
        return false if tokens.empty?

        entries.any? { |entry_tokens| tokens.first(entry_tokens.length) == entry_tokens }
      rescue ArgumentError
        false # unbalanced quotes etc. — fall through to the prompt
      end
    end
  end
end
