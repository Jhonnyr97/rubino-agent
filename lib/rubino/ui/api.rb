# frozen_string_literal: true

require "securerandom"
require "time"

module Rubino
  module UI
    # Bridge between Agent::Runner and the HTTP API.
    #
    # Streaming output (info/success/stream/...) is appended to an in-memory
    # event buffer that the API server drains over SSE.
    #
    # Interactive prompts cross threads through an ApprovalGate:
    # - #confirm emits `approval.required` on the recorder and blocks on the
    #   gate until an HTTP client posts a decision.
    # - #ask emits `clarify.required` and blocks the same way.
    #
    # When no gate/recorder is wired (CLI or test contexts), both calls fall
    # back to auto-approve (#confirm -> true, #ask -> nil).
    #
    # APPROVE_DECISIONS lists the decision strings that count as approve;
    # anything else yields a false from #confirm. The two deny forms differ
    # only in persistence: "deny" denies this call ONCE (nothing remembered,
    # re-prompts next session); "deny_always" additionally persists a
    # permissions:deny rule so ApprovalPolicy#decide auto-denies the pattern
    # across sessions. The set is kept in sync with Schemas::DecideApproval so
    # every value the HTTP boundary accepts is either an approve or an explicit
    # deny — no unreachable values, no silent denies from typos. `always` is a
    # back-compat alias for `always_command` (existing web clients post it).
    class API < Base
      APPROVE_DECISIONS = %w[once session always always_prefix always_command].freeze

      # `always` from older web clients means the narrow "always this command"
      # form (== always_command); normalized away before decision handling.
      ALWAYS_ALIAS = { "always" => "always_command" }.freeze

      attr_reader :events

      def initialize(gate: nil, recorder: nil, session_id: nil, approval_cache: nil)
        @gate = gate
        @recorder = recorder
        @session_id = session_id
        @approval_cache = approval_cache || Rubino::Run::SessionApprovalCache.instance
        @events = []
      end

      # The API adapter parks the run on the ApprovalGate for approvals
      # (#confirm) and clarifications (#ask) — but only when a gate AND recorder
      # are actually wired. Without them both calls auto-resolve and never block,
      # so the loop can keep streaming. Drives Loop#interactive_turn?.
      def blocking_human_input?
        !@gate.nil? && !@recorder.nil?
      end

      def info(message) = emit_event(:info, message: message)

      def success(message) = emit_event(:success, message: message)
      def warning(message) = emit_event(:warning, message: message)
      def error(message) = emit_event(:error, message: message)
      def status(message) = emit_event(:status, message: message)
      def note(text) = emit_event(:note, text: text)
      def assistant_text(text) = emit_event(:assistant_text, text: text)

      # The adapter no longer drops :thinking deltas in hidden mode (the CLI
      # retains them unrendered for the Ctrl-O reveal, #76); the HTTP wire
      # keeps the old contract — hidden means no reasoning deltas reach
      # API consumers, so the gate lives here now.
      def stream(chunk)
        return if chunk.is_a?(Hash) && chunk[:type] == :thinking &&
                  Config::ReasoningPrefs.mode(Rubino.configuration) == :hidden

        emit_event(:stream, chunk: chunk)
      end

      def stream_end = emit_event(:stream_end)
      def thinking_started = emit_event(:thinking_started)
      def table(headers:, rows:) = emit_event(:table, headers: headers, rows: rows)

      def tool_started(name, arguments: nil, at: nil)
        emit_event(:tool_started, name: name, arguments: arguments, at: at)
      end

      def tool_body(text, kind: :plain) = emit_event(:tool_body, text: text, kind: kind)
      def tool_chunk(name, chunk) = emit_event(:tool_chunk, name: name, chunk: chunk)
      def tool_finished(name, result: nil) = emit_event(:tool_finished, name: name)
      def compression_started(at: nil) = emit_event(:compression_started, at: at)

      def compression_finished(metadata, at: nil)
        emit_event(:compression_finished, metadata: metadata, at: at)
      end

      def job_enqueued(type) = emit_event(:job_enqueued, type: type)
      def job_started(type) = emit_event(:job_started, type: type)
      def job_finished(type) = emit_event(:job_finished, type: type)
      def separator = emit_event(:separator)
      def blank_line = emit_event(:blank_line)
      def mode_changed(name, previous: nil) = emit_event(:mode_changed, mode: name, previous: previous)
      def reasoning_status(mode) = emit_event(:reasoning_status, mode: mode)
      def reasoning_changed(mode, previous: nil) = emit_event(:reasoning_changed, mode: mode, previous: previous)
      def think_status(effort) = emit_event(:think_status, effort: effort)
      def think_changed(effort, previous: nil) = emit_event(:think_changed, effort: effort, previous: previous)

      # Emits `approval.required` and blocks on the ApprovalGate until an
      # HTTP client posts a decision for the generated approval_id.
      # Auto-approves (returns true) when no gate/recorder is wired.
      #
      # @param question [String] human-readable approval prompt
      # @param scope    [String, nil] cache key for "session"/"always"
      #   decisions; pass `"<tool>:<args>"` so a second call with the
      #   same shape bypasses the user prompt entirely. Nil opts out.
      # @param tool     [String, nil] tool name, for the enriched event.
      # @param command  [String, nil] literal command/args, for the event +
      #   prefix derivation when a decision persists.
      # @param pattern_key [String, nil] matched dangerous-pattern key, if any.
      # @param description [String, nil] dangerous-pattern description, if any.
      # @return [Boolean] true when the decision is in APPROVE_DECISIONS;
      #   false on an explicit deny OR when the gate's wait deadline elapses
      #   with no answer (abandoned run) — the safe auto-DENY default.
      def confirm(question, scope: nil, tool: nil, command: nil, pattern_key: nil, description: nil)
        return true unless @gate && @recorder

        # Session-scope short-circuit: a prior "session" / "always_*"
        # decision (or a persisted prefix) for this scope means we must NOT
        # prompt again in the same session.
        return true if scope && @session_id && @approval_cache.allowed?(@session_id, scope)

        rule = derive_rule(tool, command, pattern_key)

        approval_id = SecureRandom.uuid
        # Register before emitting: a fast HTTP client could POST a decision
        # the moment it sees approval.required, racing past #await; the gate
        # must already know the id is valid by then.
        @gate.register(approval_id, recorder: @recorder)
        @recorder.emit(
          "approval.required",
          approval_payload(approval_id, question, tool: tool, command: command,
                                                  pattern_key: pattern_key, description: description, rule: rule)
        )
        decision = @gate.await(approval_id)
        # Wait deadline elapsed with no human answer (abandoned run): the gate
        # already emitted approval.expired. Resolve to a safe DENY — NEVER an
        # auto-approve — so the gated command does not run.
        return false if decision.equal?(Run::ApprovalGate::EXPIRED)

        normalized = normalize_decision(decision)
        approved = APPROVE_DECISIONS.include?(normalized)

        if approved
          apply_decision(normalized, scope: scope, command: command, rule: rule)
        elsif normalized == "deny_always"
          # Not an approve, but PERSIST the deny so ApprovalPolicy#decide
          # auto-denies this pattern across sessions (it checks permissions:deny
          # first). Plain "deny" stays a one-off — nothing persisted, re-prompts.
          persist_deny(tool, command, rule)
        end
        approved
      end

      # Emits `clarify.required` and blocks on the ApprovalGate until an
      # HTTP client posts a clarification response for the generated
      # clarify_id. Returns nil when no gate/recorder is wired.
      #
      # @param prompt [String] question to ask the user
      # @return [String, nil] the response text, or nil in non-API contexts
      #   or when the wait deadline elapsed with no answer (abandoned run)
      def ask(prompt)
        return nil unless @gate && @recorder

        clarify_id = SecureRandom.uuid
        @gate.register(clarify_id, recorder: @recorder)
        @recorder.emit("clarify.required", { clarify_id: clarify_id, question: prompt.to_s })
        answer = @gate.await(clarify_id)
        # Deadline elapsed with no answer: the gate emitted approval.expired;
        # treat an abandoned clarification as "no response".
        return nil if answer.equal?(Run::ApprovalGate::EXPIRED)

        answer
      end

      private

      # Maps `always` (legacy web) to its canonical form; everything else
      # passes through lowercased.
      def normalize_decision(decision)
        d = decision.to_s.downcase
        ALWAYS_ALIAS.fetch(d, d)
      end

      # The rule this approval would be remembered/persisted as, derived from
      # the command. Nil when there is no command (tool-wide / structured-arg
      # tools), in which case no prefix is offered and persistence is skipped.
      def derive_rule(tool, command, pattern_key)
        return nil if command.to_s.strip.empty?

        Security::PrefixDeriver.rule_for(tool: tool.to_s, command: command.to_s, pattern_key: pattern_key)
      end

      # The enriched approval.required payload. New fields are additive on top
      # of the original {approval_id, question}; `hardline` is always false here
      # (a hardline command is denied upstream and never reaches #confirm).
      def approval_payload(approval_id, question, tool:, command:, pattern_key:, description:, rule:)
        suggested = rule&.kind == :prefix ? rule.value : nil
        {
          approval_id: approval_id,
          question: question.to_s,
          command: command.to_s,
          tool: tool.to_s,
          description: description.to_s,
          hardline: false,
          suggested_prefix: suggested,
          pattern_key: pattern_key,
          choices: choices_for(suggested)
        }
      end

      # The decisions the gem offers for THIS request. Always once/always_command/
      # deny; session whenever in-memory caching applies (a gated run with a
      # session id); always_prefix only when a :prefix rule is derivable. The web
      # reads this list instead of synthesizing it.
      def choices_for(suggested_prefix)
        choices = %w[once]
        choices << "session" if @session_id
        choices << "always_prefix" if suggested_prefix
        choices << "always_command"
        choices << "deny"
        choices << "deny_always"
        choices
      end

      # Routes an approved decision to its cache/persister action:
      #   once           -> nothing (this call only)
      #   session        -> in-memory cache, dies with the process
      #   always_prefix  -> persist the derived :prefix rule to command_allowlist
      #   always_command -> persist the NARROW rule (pattern key / exact command)
      # `always` was already normalized to always_command upstream.
      def apply_decision(decision, scope:, command:, rule:)
        case decision
        when "session"
          remember_session(scope)
        when "always_prefix"
          remember_session(scope)
          persist_rule(prefix_rule(rule, command))
        when "always_command"
          remember_session(scope)
          persist_rule(narrow_rule(command))
        end
      end

      def remember_session(scope)
        return unless scope && @session_id

        @approval_cache.remember(@session_id, scope, "session")
      end

      # Persists a rule value to the on-disk command_allowlist so it pre-approves
      # siblings across restarts (CommandAllowlist prefix start_with?). Skips when
      # there is no value to persist.
      def persist_rule(rule)
        Security::AllowlistPersister.persist(rule.value) if rule
      end

      # Persists a permissions:deny rule for the "deny_always" decision, scoped
      # the SAME way the allow side scopes (derived :prefix when available, else
      # the exact command). ApprovalPolicy#decide checks permissions:deny first,
      # so this auto-denies the pattern across sessions. No-op when there is no
      # pattern to key on. Same DenyPersister path the CLI uses.
      def persist_deny(tool, command, rule)
        pattern = Security::DenyPersister.pattern_for(
          tool: tool.to_s, rule: rule, command: command
        )
        Security::DenyPersister.persist(pattern) if pattern
      end

      # The broad prefix rule for always_prefix. Falls back to deriving from the
      # raw command when the caller didn't pass a tool-derived rule.
      def prefix_rule(rule, command)
        return rule if rule&.kind == :prefix

        derived = Security::PrefixDeriver.rule_for(tool: "shell", command: command.to_s)
        derived if derived&.kind == :prefix
      end

      # The narrow rule for always_command: exact command, or the dangerous
      # pattern key when the command is dangerous (S3 semantics).
      def narrow_rule(command)
        return nil if command.to_s.strip.empty?

        Security::PrefixDeriver.narrow_rule_for(tool: "shell", command: command.to_s)
      end

      def emit_event(type, **payload)
        @events << { type: type, payload: payload, timestamp: Time.now.iso8601 }
      end
    end
  end
end
