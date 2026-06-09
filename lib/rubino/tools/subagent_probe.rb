# frozen_string_literal: true

require_relative "../llm/adapter_factory"

module Rubino
  module Tools
    # probe — the parent\'s EPHEMERAL read-only peek into a running subagent (the
    # second mechanism of the parent<->subagent comm design).
    #
    # Unlike `steer` (a persisted note that changes the child\'s trajectory),
    # `probe` is read-only and DISCARDED: it takes a SNAPSHOT of the child\'s
    # current messages, runs ONE side-inference ([child messages] + question) on
    # the child\'s own model, and returns the answer to the parent. Nothing is
    # appended to the child\'s history, the child\'s loop is never touched, and
    # the Q&A never enters the timeline — so a probe can never alter what the
    # subagent does. The cost is one extra model round-trip that is billed but
    # thrown away (keep probes short).
    #
    # Reuse: the snapshot is just Session::Store#for_session on the child\'s own
    # session id (the child Runner exposes #session); the inference is a one-shot
    # AdapterFactory.build(...).chat — the SAME adapter seam Lifecycle and the
    # auxiliary client use. No new transport, no shared state.
    class SubagentProbe
      # The instruction prepended to the one-shot so the child\'s model answers AS
      # the subagent, from its context-so-far, without trying to continue the task.
      PREAMBLE = "You are the subagent above. Answer the following question from " + "your current context ONLY — do not take any action or continue " + "your task; this is a read-only check. Be brief."

      # @param adapter_factory [#call] test seam: a callable taking the resolved
      #   model id and returning an LLM adapter (anything responding to #chat).
      #   Defaults to the real AdapterFactory.build for the child\'s model.
      def initialize(adapter_factory: nil, message_store: nil)
        @adapter_factory = adapter_factory
        @message_store   = message_store
      end

      # Runs the ephemeral peek and returns the answer string. Best-effort: any
      # failure (no session yet, model error) returns a short diagnostic rather
      # than raising — a probe must never break the parent REPL.
      def peek(entry:, question:)
        snapshot = snapshot_messages(entry)
        messages = [{ role: "user", content: PREAMBLE }] + snapshot +
                   [{ role: "user", content: question.to_s }]

        adapter  = build_adapter(entry)
        response = adapter.chat(messages: messages)
        text     = response.respond_to?(:content) ? response.content.to_s : response.to_s
        text.strip.empty? ? "(no answer)" : text.strip
      rescue StandardError => e
        "(probe failed: #{e.message})"
      end

      private

      # The child\'s current transcript as plain {role:, content:} text messages.
      # Tool/assistant rows with no textual content are dropped (the peek only
      # needs the readable context, not the tool_use/result wiring), so the
      # snapshot is a clean prompt the one-shot model can answer from.
      def snapshot_messages(entry)
        session = entry.runner&.session
        return [] unless session && session[:id]

        store.for_session(session[:id]).filter_map do |m|
          c = m.content.to_s
          next if c.strip.empty?

          { role: normalize_role(m.role), content: c }
        end
      end

      # Map persisted roles to the chat roles the adapter expects; a `tool` row
      # becomes a user-visible context line (its content is the tool output).
      def normalize_role(role)
        %w[user assistant].include?(role.to_s) ? role.to_s : "user"
      end

      def store
        @message_store ||= Session::Store.new
      end

      def build_adapter(entry)
        model = (entry.runner.respond_to?(:model_id) ? entry.runner.model_id : nil) if entry.runner
        model ||= Rubino.configuration.model_default
        return @adapter_factory.call(model) if @adapter_factory

        LLM::AdapterFactory.build(model_id: model, config: Rubino.configuration)
      end
    end
  end
end
