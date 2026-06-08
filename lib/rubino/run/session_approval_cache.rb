# frozen_string_literal: true

module Rubino
  module Run
    # Remembers approval decisions that should survive past the current
    # call so the agent doesn't re-prompt the user for the same operation
    # in the same session.
    #
    # Granularity: a decision is stored as a DERIVED RULE, not the exact
    # "<tool>:<command>" string. The caller still passes a scope shaped like
    # "shell:rm -rf /tmp/cache" or "write:report.md"; the cache splits it into
    # (tool, command) and asks Security::PrefixDeriver for the rule to remember.
    # This mirrors the reference, which keys session approvals on a PATTERN KEY rather
    # than the raw command (approve_session / is_approved). The practical effect for S3:
    #   - a DANGEROUS command remembers its pattern CLASS, so approving e.g.
    #     `git push --force origin main` once also covers `git push -f other`
    #     in the same session (same "git force push" class);
    #   - a PLAIN command still remembers only the exact command, so approving
    #     `git status` does NOT auto-approve `git diff` (narrow for S3; the
    #     broad prefix rule is derived but wired into a decision only in S5).
    #
    # A scope with no ":" (a tool-wide scope like "shell") has no command to
    # derive from and is stored/matched verbatim.
    #
    # Persistence: in-memory, process-lifetime. "session" decisions die with
    # the process; "always" would deserve disk persistence but isn't wired up
    # yet (S5), so we treat both as session-scoped for now.
    #
    # Thread-safe: every read/write goes through @mutex.
    class SessionApprovalCache
      # Singleton accessor. We don't use Dry::Container or similar here
      # because the cache is process-global state that the runner needs
      # to inject into per-run UI::API instances; one shared object is
      # the simplest expression of "remember across runs of the same
      # session".
      def self.instance
        @instance ||= new
      end

      # Resets the singleton — used by tests that need a clean slate.
      # Avoids hidden cross-test leakage when specs share the process.
      def self.reset_singleton!
        @instance = nil
      end

      # Decisions that should be persisted on approval.
      REMEMBERED_DECISIONS = %w[session always].freeze

      def initialize
        @data = Hash.new { |h, k| h[k] = [] } # session_id => [Rule, ...]
        @mutex = Mutex.new
      end

      # Records a decision for (session_id, scope) as a derived rule. No-op
      # when either value is blank, or the decision isn't a remembered kind.
      def remember(session_id, scope, decision)
        return unless session_id && scope
        return unless REMEMBERED_DECISIONS.include?(decision.to_s.downcase)

        rule = rule_for_scope(scope)
        @mutex.synchronize do
          rules = @data[session_id.to_s]
          rules << rule unless rules.any? { |r| r == rule }
        end
      end

      # True when a prior decision for this session already covers the command
      # carried by `scope` — pattern-class membership, prefix start_with?, or an
      # exact-command match, per the stored rule kinds.
      def allowed?(session_id, scope)
        return false unless session_id && scope

        command = scope_command(scope)
        @mutex.synchronize do
          @data[session_id.to_s].any? { |rule| rule.covers?(command) }
        end
      end

      # Drops every cached decision for one session (e.g. after a
      # session is deleted). Pass nil to wipe every session.
      def forget!(session_id = nil)
        @mutex.synchronize do
          if session_id
            @data.delete(session_id.to_s)
          else
            @data.clear
          end
        end
      end

      private

      # Splits a "<tool>:<command>" scope into the rule to remember. A scope
      # without a ":" is tool-wide (no command) — remember it verbatim as an
      # exact rule so the tool-scope short-circuit in UI::CLI keeps working.
      def rule_for_scope(scope)
        tool, command = split_scope(scope)
        return Security::PrefixDeriver::Rule.new(kind: :command, value: scope.to_s) if command.nil?

        Security::PrefixDeriver.narrow_rule_for(tool: tool, command: command)
      end

      # The command a query scope refers to: the part after the first ":",
      # or the whole scope when there is none (tool-wide scope matched verbatim).
      def scope_command(scope)
        _tool, command = split_scope(scope)
        command.nil? ? scope.to_s : command
      end

      def split_scope(scope)
        str = scope.to_s
        return [str, nil] unless str.include?(":")

        str.split(":", 2)
      end
    end
  end
end
