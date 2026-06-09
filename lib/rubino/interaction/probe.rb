# frozen_string_literal: true

module Rubino
  module Interaction
    # An ephemeral, read-only side-question against the CURRENT session.
    #
    # `probe` is the principal-chat counterpart of the subagent-level probe:
    # it answers a lateral question from the session's context-so-far and then
    # VANISHES — neither the question nor the answer is written to the session
    # transcript, so the next real turn proceeds exactly as if it never happened
    # (Claude Code's `/btw` semantics).
    #
    # Reuse, not reinvention:
    #   - Context::PromptAssembler.build gives the SAME message array a real
    #     turn would send (system + summary + history snapshot). We append the
    #     question as a final user message and call the adapter ONCE.
    #   - LLM::AdapterFactory.build(...).chat(messages:, tools: nil) is the
    #     existing one-shot completion seam — no Loop, no tools, no persistence.
    #
    # Nothing here touches Session::Store, so the probe is screen-only: the only
    # artifact is the dim aside the CLI renders.
    class Probe
      Result = Struct.new(:question, :answer, keyword_init: true)

      def initialize(session:, config: Rubino.configuration, model_override: nil,
                     provider_override: nil)
        @session           = session
        @config            = config
        @model_override    = model_override
        @provider_override = provider_override
      end

      # Runs the one-shot side-inference over a SNAPSHOT of the session and the
      # question. Returns a Result(question:, answer:). Read-only: the session's
      # message store is never written.
      def ask(question)
        messages = snapshot_messages
        messages << { role: "user", content: question }

        adapter  = LLM::AdapterFactory.build(
          model_id: @model_override || @session[:model],
          provider: @provider_override || @config.model_provider,
          config: @config
        )
        response = adapter.chat(messages: messages, tools: nil)

        Result.new(question: question, answer: response.content.to_s)
      end

      private

      # The exact message array a real turn would assemble for this session —
      # system prompt + summary + the full history so far — minus the new turn.
      # Memory context is left empty: a probe is a quick aside, and skipping the
      # memory snapshot keeps it cheap and side-effect-free.
      def snapshot_messages
        Context::PromptAssembler.new(
          session: @session,
          memory_context: {},
          config: @config
        ).build
      end
    end
  end
end
