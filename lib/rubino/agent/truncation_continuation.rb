# frozen_string_literal: true

module Rubino
  module Agent
    # Stitches a response truncated by the output-token limit back together.
    #
    # Faithful port of the reference finish_reason=="length" continuation
    # (the per-turn loop plus the boosted output budget). When a model call comes back with
    # stop_reason==:length and NO tool calls, the answer was cut mid-sentence by
    # max_tokens. Rather than surface the fragment as the final turn, we:
    #
    #   1. keep the interim partial as an assistant message in the history,
    #   2. append a "[System: …continue exactly where you left off…]" user nudge,
    #   3. re-issue the SAME request with a progressively BOOSTED output budget
    #      (base × (retry+1), capped at 32 768), and
    #   4. concatenate the partial pieces into the final answer.
    #
    # Up to MAX_RETRIES (3, matching the reference `length_continue_retries < 3`)
    # continuations are attempted; if it is still truncated after that, the
    # stitched-together partial is returned as-is (the reference returns it with
    # partial=True / "remained truncated after 3 continuation attempts").
    #
    # The class is transport-agnostic: it issues each continuation through a
    # +boundary+ callable (`boundary.call(request) -> AdapterResponse`) so it
    # unit-tests against fixtures with no network. The caller (Loop) builds the
    # first request and passes the first response in.
    class TruncationContinuation
      # The `length_continue_retries < 3` ceiling.
      MAX_RETRIES = 3
      # Fallback base when agent.max_tokens is unset.
      DEFAULT_BASE = 4096
      # Boost cap.
      BOOST_CAP = 32_768

      # The continuation nudge for an ordinary output-length truncation
      # (the `else` branch of the continuation-prompt builder). The
      # partial-stream-stub variants don't apply here — a dropped stream surfaces
      # as AdapterResponse#interrupted?, handled separately by the Loop.
      CONTINUATION_NUDGE =
        "[System: Your previous response was truncated by the output " \
        "length limit. Continue exactly where you left off. Do not " \
        "restart or repeat prior text. Finish the answer directly.]"

      # +boundary+    : responds to #call(request, &block) → AdapterResponse.
      # +base_tokens+ : the configured agent.max_tokens (nil ⇒ DEFAULT_BASE).
      # +ui+          : optional, gets #note on each continuation attempt.
      def initialize(boundary:, base_tokens: nil, ui: nil)
        @boundary    = boundary
        @base_tokens = base_tokens
        @ui          = ui
      end

      # True iff +response+ is a length-truncated turn that warrants continuation:
      # stopped on the output limit AND carries no tool calls (a truncated
      # tool-call turn is a different repair path — out of scope here, as in
      # the reference's separate truncated_tool_call branch).
      def applicable?(response)
        response&.stop_reason == :length && !response.has_tool_calls?
      end

      # Drive the continuation loop. +request+ is the LLM::Request that produced
      # +first_response+; +first_response+ is the truncated AdapterResponse.
      # Re-issues with a boosted budget until the model stops cleanly or
      # MAX_RETRIES is hit, then returns ONE AdapterResponse whose content is the
      # stitched-together answer. A passed block forwards stream chunks straight
      # through to the boundary on each continuation call.
      #
      # If +first_response+ is not applicable? this returns it untouched, so the
      # Loop can call #continue unconditionally.
      def continue(request, first_response, &block)
        return first_response unless applicable?(first_response)

        parts    = collect_part(first_response)
        response = first_response
        retries  = 0

        while applicable?(response) && retries < MAX_RETRIES
          retries += 1
          @ui&.note("↻ Requesting continuation (#{retries}/#{MAX_RETRIES})…")

          # Keep the interim partial in history, then nudge the model to resume.
          messages = request.messages.dup
          messages << { role: "assistant", content: response.content.to_s }
          messages << { role: "user", content: CONTINUATION_NUDGE }

          request  = reissue(request, messages, retries)
          response = @boundary.call(request, &block)
          parts.concat(collect_part(response))
        end

        stitch(response, parts)
      end

      private

      # Build the next request: same shape, continued history, boosted budget.
      def reissue(request, messages, retries)
        LLM::Request.new(
          messages:    messages,
          tools:       request.tools,
          temperature: request.temperature,
          max_tokens:  boosted_max_tokens(retries),
          thinking:    request.thinking,
          prefill:     request.prefill,
          image_paths: request.image_paths,
          stream:      request.stream?
        )
      end

      # Progressive boost: base × (retries+1), capped. On the
      # first continuation (retries==1) the budget is 2× base, then 3×, …
      def boosted_max_tokens(retries)
        base = @base_tokens && @base_tokens.positive? ? @base_tokens : DEFAULT_BASE
        [base * (retries + 1), BOOST_CAP].min
      end

      def collect_part(response)
        text = response.content.to_s
        text.empty? ? [] : [text]
      end

      # Final stitched response: concatenated content, carrying the LAST call's
      # token usage / model id / stop_reason (the spend already happened, and the
      # final stop_reason tells the caller whether it ever completed cleanly).
      def stitch(last_response, parts)
        LLM::AdapterResponse.new(
          content:       parts.join,
          tool_calls:    last_response.tool_calls,
          input_tokens:  last_response.input_tokens,
          output_tokens: last_response.output_tokens,
          model_id:      last_response.model_id,
          stop_reason:   last_response.stop_reason
        )
      end
    end
  end
end
