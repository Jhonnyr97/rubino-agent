# frozen_string_literal: true

require "ruby_llm"
require "faraday"
require "net/http"
require_relative "tool_bridge"
require_relative "cache_breakpoint_middleware"
require_relative "inline_think_filter"
require_relative "provider_resolver"
require_relative "reasoning_manager"
require_relative "thinking_support"

module Rubino
  module LLM
    # Raised when a stream goes silent past stale_chunk_timeout. (#22)
    class StreamStaleError < StandardError; end

    # Transport-level drops that surface mid-request. The canonical list lives
    # on ErrorClassifier (the single source of truth for retryability); aliased
    # here for the stream-path `rescue *STREAM_DROP_ERRORS` and existing specs.
    # faraday-net_http re-raises IOError/EOFError (and friends) as
    # Faraday::ConnectionFailed, so that is the type we actually see for an
    # upstream socket close (message often "end of file reached"). Retried ONLY
    # before the first streamed chunk — see #stream_once.
    STREAM_DROP_ERRORS = ErrorClassifier::STREAM_DROP_ERRORS

    # Adapter wrapping ruby_llm to isolate all LLM integration details.
    # The rest of the application never calls ruby_llm directly.
    class RubyLLMAdapter
      attr_reader :model_id, :provider

      def initialize(model_id: nil, provider: nil, config: nil, ui: nil, event_bus: nil,
                     tool_executor: nil, cancel_token: nil, isolate_config: false)
        @config        = config || Rubino.configuration
        @model_id      = model_id || @config.dig("model", "default")
        @provider      = provider || resolve_provider
        @temperature   = @config.dig("model", "temperature")
        @ui            = ui || Rubino.ui
        @event_bus     = event_bus || Rubino.event_bus
        @tool_executor = tool_executor # nil = ToolBridge falls back to direct tool.call
        @cancel_token  = cancel_token

        # SLICE-7: when built as a FallbackChain entry, scope provider config
        # (api keys / base_url / timeout) into a per-adapter RubyLLM::Context
        # instead of the process-global RubyLLM.configure. This is the heart of
        # the global-config hazard fix: switching providers
        # for a fallback must NOT mutate the global, or concurrent sessions on the
        # API/server path corrupt each other's provider config. The primary
        # adapter (isolate_config: false) keeps writing the global exactly as
        # before, so existing single-provider setups are byte-identical.
        if isolate_config
          @context = RubyLLM.context { |c| apply_provider_config!(c) }
        else
          configure_ruby_llm!
        end
      end

      # The single LLM boundary entry: take one
      # LLM::Request, dispatch to the streaming vs non-streaming transport based
      # on request.stream, and return a normalized AdapterResponse. The streaming
      # variant yields chunks to the block then returns the same Response. This
      # is the front door the conversation loop depends on; #chat / #stream
      # remain as the underlying transports and stay valid for existing callers.
      #
      # Graceful thinking degradation (#75): a provider on the anthropic-
      # compatible path that rejects the thinking budget used to hard-error the
      # user's very first prompt (the default effort is medium). When the
      # rejection is recognised, remember it for the session, tell the user
      # once, and retry this same request WITHOUT the budget. Safe to re-issue:
      # the rejection is a pre-stream 400, so no token reached the UI.
      def call(request, &)
        dispatch(request, &)
      rescue StandardError => e
        raise unless thinking_budget_rejected?(e)

        ThinkingSupport.mark_unsupported!(@provider, notify: @ui)
        dispatch(request, &)
      end

      # Sends a chat completion request (non-streaming). image_paths, if any,
      # are forwarded to ruby_llm's `with:` slot so the primary model ingests
      # the bytes natively (no `vision` tool round-trip). Only meaningful on
      # the first model call of a turn — Loop strips it for follow-ups.
      def chat(messages:, tools: nil, response_format: nil, image_paths: [], prefill: nil,
               on_intermediate_message: nil, on_round_trip: nil, budget_exhausted: nil)
        if bedrock_bearer_mode?
          bedrock_bearer_client.chat(messages: messages, tools: tools)
        else
          chat_instance = build_chat(tools: tools, response_format: response_format,
                                     budget_exhausted: budget_exhausted)
          load_history(chat_instance, messages)
          apply_prefill(chat_instance, prefill)
          usage = wire_round_trip_callbacks(chat_instance,
                                            on_intermediate_message: on_intermediate_message,
                                            on_round_trip: on_round_trip)
          response = chat_instance.ask(last_user_content(messages), with: presence(image_paths))
          build_response(response, usage: usage)
        end
      end

      # Sends a streaming chat request, yielding chunks. Inline <think>…</think>
      # sentinels are routed to the :thinking channel. Buffered partial content
      # is preserved across mid-stream parse errors so downstream code can show
      # whatever the model produced before the failure.
      def stream(messages:, tools: nil, response_format: nil, image_paths: [], prefill: nil,
                 on_intermediate_message: nil, on_round_trip: nil, budget_exhausted: nil, &)
        if bedrock_bearer_mode?
          # BedrockBearerClient#stream buffers the whole /converse response before
          # its first emit, so a transport error can only fire pre-first-chunk —
          # no token reached the UI. It raises straight through to the runner,
          # which re-issues a fresh request (safe, no double output).
          return bedrock_bearer_client.stream(messages: messages, tools: tools, &)
        end

        # No retry wrapper here — retry ownership moved to Agent::ModelCallRunner
        # (Slice 4) to avoid double-retrying the same failure. The streaming
        # transport-drop PROTECTION still lives inside #stream_once: it RAISES a
        # transport drop only when NOTHING was emitted to the UI yet
        # (chunks_seen.zero?), so the runner can re-issue a fresh request before
        # any token reached the user — no double output. Once a chunk has flowed
        # it RETURNS the buffered partial instead of raising, so the drop can
        # never be retried mid-stream. The raise-vs-return decision (the only
        # streaming-specific safety) stays here; the actual retrying is the
        # runner's job.
        stream_once(messages: messages, tools: tools, response_format: response_format,
                    image_paths: image_paths, prefill: prefill,
                    on_intermediate_message: on_intermediate_message,
                    on_round_trip: on_round_trip, budget_exhausted: budget_exhausted, &)
      end

      # Returns model information (context window, etc.)
      def model_info
        RubyLLM.models.find(@model_id)
      rescue StandardError
        nil
      end

      # Returns the context window size for the current model
      def context_window
        info = model_info
        return @config.dig("model", "context_length") if @config.dig("model", "context_length")

        info&.context_window || 128_000
      end

      private

      # The raw #call dispatch (streaming vs non-streaming), shared by the
      # normal path and the one-shot thinking-budget retry (#75).
      def dispatch(request, &)
        # Per-turn round-trip hooks (#355 #351) ride on the Request; pass them so
        # the streaming/non-streaming transports can wire the ruby_llm callbacks
        # (intermediate-message persistence, round-trip counting) and ToolBridge
        # can consult the budget-exhausted predicate for graceful Halt.
        hooks = {
          on_intermediate_message: request.on_intermediate_message,
          on_round_trip: request.on_round_trip,
          budget_exhausted: request.budget_exhausted
        }
        if request.stream?
          stream(messages: request.messages, tools: request.tools,
                 image_paths: request.image_paths, prefill: request.prefill, **hooks, &)
        else
          chat(messages: request.messages, tools: request.tools,
               image_paths: request.image_paths, prefill: request.prefill, **hooks)
        end
      end

      # True when +error+ is a provider's "thinking (budget) is not supported"
      # rejection AND this request actually carried a budget (#75). Once the
      # provider is marked unsupported the budget drops to 0, so this can never
      # match twice — no retry loop.
      def thinking_budget_rejected?(error)
        anthropic_generation_path? && thinking_budget.positive? &&
          ThinkingSupport.rejection?(error)
      end

      # One streaming attempt. See #stream for the retry / no-double-output
      # contract. Inline <think>…</think> sentinels are routed to :thinking;
      # buffered content is preserved across mid-stream parse/transport errors.
      def stream_once(messages:, tools:, response_format:, image_paths:, prefill: nil,
                      on_intermediate_message: nil, on_round_trip: nil, budget_exhausted: nil, &block)
        chat_instance = build_chat(tools: tools, response_format: response_format,
                                   budget_exhausted: budget_exhausted)
        load_history(chat_instance, messages)
        apply_prefill(chat_instance, prefill)

        # Round-trip accounting (#355 #351): registered ADDITIVELY so it does not
        # disturb the block-id wiring below (ruby_llm appends callbacks, never
        # replaces). Persists intermediate assistant(tool_use) messages, counts
        # round-trips for the budget, and sums per-message usage across the whole
        # in-ask tool loop. Sums are read back into build_response so token_total
        # reflects EVERY round-trip's spend, not just the final message.
        usage = wire_round_trip_callbacks(chat_instance,
                                          on_intermediate_message: on_intermediate_message,
                                          on_round_trip: on_round_trip)

        think_filter  = InlineThinkFilter.new
        buffered      = +""
        last_chunk_at = monotonic_now
        stale_after   = stale_chunk_timeout
        chunks_seen   = 0
        # #488: a tool that ruby_llm runs MID-STREAM (e.g. a blocking ask_parent
        # parked on a human answer for up to tasks.ask_parent_timeout = 900s)
        # produces no chunks while it runs, so the stale watchdog below would
        # otherwise count that legitimate tool runtime as stream-idle and fire at
        # `stale_after` (300s default), pre-empting the configured ask timeout and
        # making the "auto-resumes in 15m" banner a lie. While a tool is in flight
        # the stream is intentionally paused, not stalled: suspend idle accrual for
        # its duration. Set when a tool-use message closes (tools are about to
        # run); cleared when the next message begins (tools returned).
        tool_running = false

        # Each assistant message ruby_llm streams within this one ask() is a
        # distinct content block: on a multi-step tool turn the model emits
        # text → tool_use → (next message) text → … . We tag every content
        # delta with the current block's id so a consumer can regroup the
        # deltas that belong together instead of splitting them around the
        # tool calls that interleave mid-stream. before_message bumps the id;
        # after_message flushes the filter (so a buffered tail lands on THIS
        # block, before the tool fires) and emits the block boundary.
        message_block_id = 0

        # The text of the CURRENT content block only (#core-F1). `buffered` keeps
        # every block of the turn concatenated for the transcript/render; this
        # resets at each new block so that, when the stream finishes, it holds just
        # the LAST block — the post-final-tool answer with no pre-tool narration
        # glued on. The headless one-shot `result` surfaces this, not `buffered`.
        last_block      = +""
        last_block_seen = message_block_id

        emit = lambda do |type, text|
          next if text.nil? || text.empty?

          if type == :content
            buffered << text
            # New content block since the last content delta ⇒ start fresh, so
            # only the final block survives to the end of the stream.
            last_block.clear if message_block_id != last_block_seen
            last_block_seen = message_block_id
            last_block << text
          end

          begin
            block.call({ type: type, text: text, message_id: message_block_id })
          rescue StandardError => e
            # A UI/EventBus error must not abort the whole stream — log and
            # keep buffering so we can still build the response. (issue #6)
            log_safely(event: "llm.stream.emit_error", error: e.message, type: type)
          end
        end

        # Guarded: prefer ruby_llm's before_message/after_message (the
        # on_new_message/on_end_message names are deprecated in ruby_llm 1.x and
        # dropped in 2.0); fall back to the legacy names on older builds. A chat
        # (or test double) exposing neither simply gets no block boundaries and
        # the consumer falls back to the legacy per-adjacency grouping. Use a
        # proc (not a lambda) for the close handler so it tolerates whatever
        # arity the callback invokes it with.
        # A new message starting means any mid-stream tool from the previous
        # message has returned (#488): resume idle accrual and restart the idle
        # clock so the post-tool window is measured from now, not from the last
        # pre-tool chunk.
        bump_block = proc do
          message_block_id += 1
          tool_running  = false
          last_chunk_at = monotonic_now
        end
        if chat_instance.respond_to?(:before_message)
          chat_instance.before_message(&bump_block)
        elsif chat_instance.respond_to?(:on_new_message)
          chat_instance.on_new_message(&bump_block)
        end

        close_block = proc do |msg|
          # Flush any tail the think-filter is still holding so it is emitted
          # with THIS block's id before we close the block (and before the
          # tool call that follows a tool-use message executes). final: false —
          # the stream continues, so an incomplete tag straddling this boundary
          # is held back for the next message rather than mis-routed (STRM-3).
          flush_filter(think_filter, final: false, &emit)
          @event_bus&.emit(Interaction::Events::MESSAGE_COMPLETED, message_id: message_block_id)
          # #488: a tool-use message just closed ⇒ ruby_llm is about to run those
          # tools mid-stream. Suspend the stale watchdog's idle accrual for the
          # tool's runtime so a long, legitimate tool (a blocking ask_parent
          # waiting on the human) is not killed at `stale_after`.
          tool_running = true if intermediate_tool_message?(msg)
        end
        if chat_instance.respond_to?(:after_message)
          chat_instance.after_message(&close_block)
        elsif chat_instance.respond_to?(:on_end_message)
          chat_instance.on_end_message(&close_block)
        end

        # #552: the AUTHORITATIVE suspend signal. ruby_llm fires before_tool_call
        # immediately before it dispatches each tool mid-stream (chat.rb:375,
        # right before #execute_tool blocks). The after_message heuristic above
        # only flips `tool_running` when the tool-use assistant message closes
        # AND intermediate_tool_message?(msg) recognises it — which is unreliable
        # on the anthropic-compatible streaming path (MiniMax /anthropic), where
        # a blocking interactive tool (`question`/clarify parked on stdin, or
        # ask_parent) starts running while the watchdog still sees
        # tool_running == false and fires at `stale_after` (30s for the
        # anthropic-compatible provider) before the human can answer. Keying the
        # suspend off before_tool_call closes that window: the instant ANY tool
        # is about to execute, idle accrual is suspended for its full runtime,
        # exactly as a blocking human-input tool needs. before_message clears it
        # again when the next assistant message opens (tool returned).
        chat_instance.before_tool_call { tool_running = true } if chat_instance.respond_to?(:before_tool_call)

        # #360: the per-chunk check_stream_stale! only fires WHEN a chunk
        # arrives — so if the upstream opens the stream then goes silent (a
        # stalled SSE / a 200 that never sends an event), nothing inside the
        # callback ever runs and the only backstop is the 600s socket
        # read-timeout. Bound the idle gap INDEPENDENTLY of chunk arrival with a
        # watchdog thread that wakes on `stale_after` (300s default, well below
        # 600s; configurable via providers.<name>.stale_timeout_seconds) and, on
        # observing an idle past the deadline, raises StreamStaleError INTO this
        # streaming thread to break it out of the blocking socket read. The
        # rescue below then surfaces a clear "stream stalled" and lets the retry
        # ladder run. The closure reads `last_chunk_at`/`chunks_seen` live (they
        # are reassigned in the callback) via a shared binding. While a tool runs
        # mid-stream (`tool_running`, #488) it reports "now" so the legitimate
        # tool runtime is never counted as a stalled stream.
        watchdog = start_stale_watchdog(stale_after) { tool_running ? monotonic_now : last_chunk_at }

        begin
          response = chat_instance.ask(last_user_content(messages), with: presence(image_paths)) do |chunk|
            # User interrupt poll. Raised here propagates out of the streaming
            # callback, ruby_llm closes the upstream connection, and Loop /
            # Lifecycle catch the Interrupted exception to bail out cleanly.
            @cancel_token&.check!

            # Any chunk from upstream — content, thinking, or a tool-call delta —
            # marks this request "committed": something came back, so a later
            # drop must NOT trigger a retry (it would re-run generation and could
            # re-fire a mid-stream tool call / double the output).
            chunks_seen  += 1
            last_chunk_at = monotonic_now
            check_stream_stale!(last_chunk_at, stale_after)

            if chunk.respond_to?(:thinking) && chunk.thinking
              thinking_text = chunk.thinking.respond_to?(:text) ? chunk.thinking.text : chunk.thinking.to_s
              emit.call(:thinking, thinking_text)
            end
            think_filter.feed(chunk.content, &emit) if chunk.content.is_a?(String) && !chunk.content.empty?
          end
        rescue Rubino::Interrupted
          # Flush whatever the filter has buffered, then re-raise. Loop will
          # catch and persist the partial assistant message so the user sees
          # what arrived before they hit Esc.
          flush_filter(think_filter, &emit)
          raise
        rescue StreamStaleError => e
          # The stream stalled (no chunk within the idle bound). If NOTHING was
          # emitted yet, RAISE so the runner re-issues a fresh request — safe, no
          # token reached the user, and the user sees "stream stalled — retrying"
          # rather than a 600s hang (#360). If chunks already flowed, preserve the
          # partial and stop (same no-double-output contract as a transport drop).
          if chunks_seen.zero?
            log_safely(event: "llm.stream.stalled", error: e.message)
            raise
          end
          log_safely(event: "llm.stream.partial", error: e.message, buffered_bytes: buffered.bytesize)
          flush_filter(think_filter, &emit)
          return partial_response(buffered)
        rescue JSON::ParserError => e
          # Preserve whatever we've buffered so far so the user sees partial
          # output instead of a blank failure. (issues #12, #22)
          log_safely(event: "llm.stream.partial", error: e.message, buffered_bytes: buffered.bytesize)
          flush_filter(think_filter, &emit)
          return partial_response(buffered)
        rescue *STREAM_DROP_ERRORS => e
          # A genuine transport drop (the observed M3 EOF, a connection reset, a
          # read timeout, …). If NOTHING was emitted yet, re-raise so the runner
          # (Agent::ModelCallRunner) can retry a fresh request — safe, no token
          # reached the user. If chunks already flowed, preserve the partial and
          # stop: never
          # re-issue after output. ErrorClassifier classifies these as retryable.
          raise if chunks_seen.zero?

          log_safely(event: "llm.stream.partial_interrupted", error: e.message,
                     buffered_bytes: buffered.bytesize)
          flush_filter(think_filter, &emit)
          return partial_response(buffered)
        ensure
          # Always tear the watchdog down — on success, on partial-return, and on
          # a raised StreamStaleError/transport drop — so it never leaks a thread
          # or fires against a finished stream.
          stop_stale_watchdog(watchdog)
        end

        # Guard flush in the same way as the per-chunk emit so a final UI error
        # doesn't lose the response. (issue #21)
        flush_filter(think_filter, event: "llm.stream.flush_error", &emit)
        build_response(response, buffered, usage: usage, final_text_block: last_block, streaming: true)
      end

      # Wires the per-round-trip ruby_llm callbacks (#355 #351) and returns a
      # mutable usage accumulator { input:, output: } the caller folds into
      # build_response. ruby_llm fires after_message once per message it appends
      # inside a single ask — the streamed/non-streamed assistant turns AND the
      # synthetic tool result messages (Chat#complete L181, #handle_tool_calls
      # L286). We:
      #   * sum input/output tokens for EVERY assistant message so the response
      #     reports the WHOLE turn's spend, not just the last message (#355b);
      #   * for an INTERMEDIATE assistant message that carries tool_calls (i.e.
      #     not the final text turn), hand the Loop a normalized hash so it
      #     persists the same assistant(tool_use) row the non-streaming path
      #     writes (#351), and bump the round-trip counter so the Loop can bound
      #     the in-ask loop against its iteration/time budget (#355a).
      #
      # IDEMPOTENCY: the final assistant TEXT message has no tool_calls, so it is
      # never sent to on_intermediate_message — the Loop keeps sole ownership of
      # persisting the final turn. Tool result messages (role :tool) are skipped
      # entirely. Registered additively, so the existing before/after_message
      # block-id wiring is untouched.
      def wire_round_trip_callbacks(chat_instance, on_intermediate_message:, on_round_trip:)
        usage = { input: 0, output: 0 }
        return usage unless chat_instance.respond_to?(:after_message)

        chat_instance.after_message do |msg|
          next if msg.nil?
          next unless msg.respond_to?(:role) && msg.role == :assistant

          usage[:input]  += msg.input_tokens.to_i  if msg.respond_to?(:input_tokens)
          usage[:output] += msg.output_tokens.to_i if msg.respond_to?(:output_tokens)

          next unless intermediate_tool_message?(msg)

          on_round_trip&.call
          on_intermediate_message&.call(normalize_intermediate(msg))
        end
        usage
      end

      # True when +msg+ is an intermediate assistant turn that requested tools
      # (so it must be persisted as an assistant(tool_use) row). The final text
      # turn carries no tool_calls and is excluded — the Loop persists it.
      def intermediate_tool_message?(msg)
        return false unless msg.respond_to?(:tool_call?)

        msg.tool_call?
      rescue StandardError
        false
      end

      # Normalizes a ruby_llm assistant(tool_use) Message into the plain hash the
      # Loop persists (mirrors AdapterResponse's tool_calls shape, so
      # persist_assistant_message stores the same metadata the non-streaming path
      # does — id/name/arguments + per-message usage).
      def normalize_intermediate(msg)
        {
          content: msg.respond_to?(:content) ? msg.content : nil,
          tool_calls: normalize_message_tool_calls(msg),
          input_tokens: msg.respond_to?(:input_tokens) ? msg.input_tokens.to_i : 0,
          output_tokens: msg.respond_to?(:output_tokens) ? msg.output_tokens.to_i : 0
        }
      end

      def normalize_message_tool_calls(msg)
        return [] unless msg.respond_to?(:tool_calls) && msg.tool_calls

        Array(msg.tool_calls).map do |tc|
          call = tc.is_a?(Array) ? tc.last : tc
          { id: call.id, name: call.name, arguments: call.arguments }
        end
      end

      # Flushes the think-filter, swallowing UI/flush errors so a late failure
      # never loses the response (issues #6, #21).
      def flush_filter(think_filter, event: "llm.stream.flush_error", final: true, &emit)
        think_filter.flush(final: final, &emit)
      rescue StandardError => e
        log_safely(event: event, error: e.message)
      end

      # Buffered-partial AdapterResponse returned when a stream is cut after at
      # least one chunk (parse error, stale, or post-first-chunk transport drop).
      # Flagged +interrupted+ so the Loop fails the turn (run.failed) instead of
      # mistaking the truncated buffer for a finished answer (the silent
      # "completed-but-empty" bug — see Rubino::StreamInterruptedError).
      def partial_response(buffered)
        AdapterResponse.new(content: buffered, tool_calls: [], input_tokens: 0,
                            output_tokens: 0, model_id: @model_id, interrupted: true)
      end

      def configure_ruby_llm!
        RubyLLM.configure { |c| apply_provider_config!(c) }
      end

      # The provider-config block, applied to a config target `c`. The primary
      # adapter passes the process-global (RubyLLM.configure); a fallback adapter
      # passes a per-call RubyLLM::Context config (SLICE-7) so the switch never
      # touches the global. Identical writes either way — only the target differs.
      def apply_provider_config!(c)
        # When RUBYLLM_DEBUG=1, dump every request/response to a log file
        # (NEVER stdout — the TUI is running on stdout). Use this to verify
        # what `tools: [...]` and `messages: [...]` actually go on the wire
        # when a provider misbehaves (e.g. emits roleplay markdown instead
        # of tool_calls).
        if ENV["RUBYLLM_DEBUG"]
          require "logger"
          require "fileutils"
          log_path = debug_log_path
          FileUtils.mkdir_p(File.dirname(log_path))
          # Build the Logger explicitly so that ruby_llm's lazy
          # `@logger ||= config.logger || Logger.new(...)` picks it up
          # even if something already touched RubyLLM.logger (its first
          # access memoizes against current config). Reset the memo too
          # so prior accesses can't shadow our injected logger.
          c.logger    = ::Logger.new(log_path, progname: "RubyLLM", level: ::Logger::DEBUG)
          c.log_level = ::Logger::DEBUG
          RubyLLM.instance_variable_set(:@logger, nil)
        end

        c.openai_api_key    = ENV["OPENAI_API_KEY"]    if ENV["OPENAI_API_KEY"]
        c.anthropic_api_key = ENV["ANTHROPIC_API_KEY"] if ENV["ANTHROPIC_API_KEY"]
        c.gemini_api_key    = ENV["GEMINI_API_KEY"]    if ENV["GEMINI_API_KEY"]

        # Bedrock IAM credentials (Mode 2 / 3)
        if ENV["BEDROCK_API_KEY"] && ENV["BEDROCK_SECRET_KEY"]
          c.bedrock_api_key       = ENV["BEDROCK_API_KEY"]
          c.bedrock_secret_key    = ENV["BEDROCK_SECRET_KEY"]
          c.bedrock_region        = ENV["BEDROCK_REGION"] || "us-east-1"
          c.bedrock_session_token = ENV["BEDROCK_SESSION_TOKEN"] if ENV["BEDROCK_SESSION_TOKEN"]
        end

        prov_cfg = provider_cfg

        # Any provider can declare openai_compatible: true in config to route
        # through the OpenAI provider with a custom base_url and API key.
        # Symmetrically, anthropic_compatible: true routes through the Anthropic
        # provider — used for backends that expose a native Anthropic-Messages
        # endpoint (e.g. MiniMax's /anthropic), which avoids the OpenAI-endpoint
        # quirks (no-[DONE] stream close, string-shaped errors).
        if openai_compatible_provider?
          c.openai_api_base = required_base_url!(prov_cfg)
          c.openai_api_key  = openai_compatible_api_key!(prov_cfg)
        elsif anthropic_compatible_provider?
          base = present_base_url(prov_cfg)
          c.anthropic_api_base = base if base
          c.anthropic_api_key  = anthropic_compatible_api_key!(prov_cfg)
        elsif @provider == "openai"
          base = present_base_url(prov_cfg)
          c.openai_api_base = base if base
        elsif native_ruby_llm_provider?(@provider)
          # A provider that ruby_llm supports natively but we don't special-case
          # above (deepseek, mistral, perplexity, xai, …). It has a stable
          # default endpoint and a `<provider>_api_key` config setter, but
          # nothing wired it before — so CredentialCheck would pass on the
          # presence of <PROVIDER>_API_KEY while the call died with
          # "Missing configuration for X: x_api_key" (#482). Wire the resolved
          # key (config first, then the native ENV var) and an optional
          # base_url override through ruby_llm's generic provider options, so
          # the preflight verdict matches what the call actually hits. Like the
          # native openai/anthropic/gemini wiring above (and unlike the
          # *_compatible paths), only set what's present and leave the gating to
          # the CredentialCheck preflight — construction must not raise on a
          # missing key (callers build the adapter just to read .provider).
          key = native_provider_api_key(prov_cfg)
          c.public_send("#{@provider}_api_key=", key) if key
          base = present_base_url(prov_cfg)
          c.public_send("#{@provider}_api_base=", base) if base
        end

        # We OWN retry/backoff in Agent::ModelCallRunner (token-gated,
        # full-jitter, safe for streaming). Disable ruby_llm's built-in
        # faraday-retry (default max=3): on 1.15 it retries POST and RE-INVOKES
        # the stream on_data handler on a drop -> double-output to the UI, and
        # it would multiply with the runner's retries into a retry storm.
        # Single source of truth.
        c.max_retries = 0

        # ruby_llm maps request_timeout -> Faraday options.timeout, which the
        # net_http adapter applies as Net::HTTP read_timeout: a PER-READ socket
        # inactivity timer that RESETS on every received chunk (NOT a total).
        # So this one knob is our first-token AND inter-token idle bound — the
        # same mechanism the OpenAI/Anthropic SDKs rely on. Size it to the
        # slowest expected gap (a cold model load before the first token); a
        # truly silent socket then fails within this many seconds as a
        # Net::ReadTimeout (-> Faraday) and is retried pre-first-token by the
        # runner. Override per backend: providers.<name>.request_timeout_seconds
        # (e.g. raise it for a large local Ollama that cold-loads for minutes).
        c.request_timeout = prov_cfg["request_timeout_seconds"] || 600
      end

      # Returns the api_key for an openai_compatible provider, or raises a
      # clear configuration error. Previously this fell back to the literal
      # "default", which would hit the upstream and surface as a cryptic 401.
      # (issue #3)
      def openai_compatible_api_key!(prov_cfg)
        compatible_api_key!(prov_cfg, env_fallback: "OPENAI_API_KEY")
      end

      # Anthropic-compatible analogue of #openai_compatible_api_key!: resolves the
      # provider key (config, then ANTHROPIC_API_KEY) or raises the same clear
      # ConfigurationError so an arbitrary Anthropic-Messages backend (MiniMax's
      # /anthropic) never silently sends an empty key and surfaces a cryptic 401.
      def anthropic_compatible_api_key!(prov_cfg)
        compatible_api_key!(prov_cfg, env_fallback: "ANTHROPIC_API_KEY")
      end

      def compatible_api_key!(prov_cfg, env_fallback:)
        key = prov_cfg["api_key"] || ENV.fetch(env_fallback, nil)
        return key if key && !key.empty?

        raise Rubino::Error,
              "Missing API key for provider '#{@provider}'. " \
              "Set providers.#{@provider}.api_key in ~/.rubino/config.yml " \
              "(e.g. ${#{@provider.to_s.upcase}_API_KEY} with the value in .env)."
      end

      # The api_key for a natively-supported provider (deepseek, mistral, …):
      # config `providers.<name>.api_key` first, then the native <PROVIDER>_API_KEY
      # ENV var (the SAME var CredentialCheck.usable? consults), or nil. Resolving
      # from the identical source as the preflight keeps the two in lockstep (#482);
      # the CredentialCheck preflight — not this wiring — gates a missing key.
      def native_provider_api_key(prov_cfg)
        key = prov_cfg["api_key"] || CredentialCheck.provider_env_key(@provider)
        key unless key.to_s.empty?
      end

      # The configured base_url, normalised to nil when blank/whitespace so a
      # config like `base_url: ""` (or a stripped-to-empty env interpolation)
      # is treated as "unset" instead of being passed through as an EMPTY api_base.
      # An empty api_base used to make the request hit an empty/garbage endpoint
      # and surface as a cryptic AUTH/connection error rather than the real cause.
      def present_base_url(prov_cfg)
        raw = prov_cfg["base_url"].to_s.strip
        raw.empty? ? nil : raw
      end

      # An openai_compatible provider has NO native default endpoint — base_url is
      # REQUIRED. A blank/empty base_url here is the actual misconfiguration, so
      # raise a clear "base_url is empty/misconfigured" error instead of letting an
      # empty api_base be sent and misattributed to a missing/invalid credential.
      def required_base_url!(prov_cfg)
        base = present_base_url(prov_cfg)
        return base if base

        raise Rubino::Error,
              "base_url is empty/misconfigured for provider '#{@provider}'. " \
              "An OpenAI-compatible provider needs a base_url — set " \
              "providers.#{@provider}.base_url in ~/.rubino/config.yml to the " \
              "endpoint (e.g. https://host/v1)."
      end

      # Resolution fallback for the direct-construction edge: AdapterFactory
      # always passes a concrete provider, so this only runs when the adapter is
      # built without one (tests, one-shot callers). Interpret the config
      # default — including "auto" and the Bedrock-bearer override — through the
      # single ProviderResolver seam rather than re-implementing it here.
      def resolve_provider
        ProviderResolver.resolve(@model_id, explicit_provider: @config.dig("model", "provider"))
      end

      def build_chat(tools: nil, response_format: nil, budget_exhausted: nil)
        options = { model: chat_model_id }
        options[:response_format] = response_format if response_format

        prov_cfg = provider_cfg

        # OpenAI-compatible providers (ollama, lm-studio, vllm, etc.):
        # route through the openai provider and skip model validation.
        # Anthropic-compatible providers (MiniMax /anthropic, etc.): route
        # through the anthropic provider, likewise skipping model validation so
        # an arbitrary model id (e.g. MiniMax-M2.7) is accepted without a
        # model-registry entry.
        if openai_compatible_provider?
          options[:provider] = :openai
          options[:assume_model_exists] = true
        elsif anthropic_compatible_provider?
          options[:provider] = :anthropic
          options[:assume_model_exists] = true
        elsif prov_cfg["assume_model_exists"]
          options[:assume_model_exists] = true
          options[:provider] = @provider.to_sym if @provider
        end

        # SLICE-7: a fallback adapter built with isolate_config: true carries a
        # per-call RubyLLM::Context so its provider config (base_url/keys/timeout)
        # never leaked into the process-global. Build the chat from that context;
        # the primary adapter (@context nil) uses the global RubyLLM.chat exactly
        # as before.
        chat = (@context || RubyLLM).chat(**options)

        apply_generation_params(chat)

        # Register tools and wire the streaming call-id capture (ToolBridge owns
        # both so the spill / tool_call_id linkage works on the streaming path —
        # STRM-2). Falls back to direct tool.call when @tool_executor is nil.
        # cache_tools (#311): on the anthropic-family path, with prompt caching
        # enabled, put a cache_control breakpoint on the last tool so the whole
        # tool block is cached. Other providers ignore cache_control, so we only
        # emit it where it is honored (and where the system breakpoint also fires).
        ToolBridge.install(chat, tools, ui: @ui, event_bus: @event_bus,
                                        tool_executor: @tool_executor,
                                        cache_tools: tool_cache_breakpoint?,
                                        budget_exhausted: budget_exhausted,
                                        cancel_token: @cancel_token,
                                        production: true)
        install_cache_middleware(chat)
        chat
      end

      # Insert the conversation-tail prompt-cache breakpoint middleware on this
      # chat's Anthropic Faraday connection (#311 growing-conversation tail).
      # Same gate as the static breakpoints (anthropic-family path + prompt_cache
      # on); a no-op on openai/ollama. The middleware sits BEFORE Faraday's JSON
      # serializer so it mutates the request Hash directly, and is idempotent —
      # registering it more than once on a reused connection is guarded by the
      # builder-handler check so we never stack duplicates.
      def install_cache_middleware(chat)
        return unless tool_cache_breakpoint?

        faraday = chat_faraday(chat)
        return unless faraday

        builder = faraday.builder
        return if builder.handlers.any? { |h| h.klass == CacheBreakpointMiddleware }

        builder.insert_before(::Faraday::Request::Json, CacheBreakpointMiddleware)
      rescue StandardError
        # Caching is a latency optimization, never a correctness requirement: if
        # ruby_llm's connection internals shift, fall back to the static
        # breakpoints rather than breaking the request path.
        nil
      end

      # Reach the live Faraday::Connection behind a RubyLLM::Chat without a
      # monkey-patch: Chat holds the Provider, Provider exposes its
      # RubyLLM::Connection (public attr_reader), whose #connection is the
      # Faraday object. Returns nil if any link is absent (defensive).
      def chat_faraday(chat)
        provider = chat.instance_variable_get(:@provider)
        return nil unless provider.respond_to?(:connection)

        rc = provider.connection
        return nil unless rc.respond_to?(:connection)

        faraday = rc.connection
        faraday.respond_to?(:builder) ? faraday : nil
      end

      # The model id handed to RubyLLM.chat. On the NATIVE path (no explicit
      # provider — ruby_llm derives the provider from the model registry), a
      # `provider/model` id like the seeded default "openai/gpt-4.1" matches an
      # OpenRouter aggregator entry in ruby_llm's registry and routes to
      # OpenRouter (→ "Missing configuration for OpenRouter") instead of the
      # OpenAI provider its prefix names. Mirror Hermes' _strip_matching_provider_prefix:
      # when the model id is prefixed with the SAME provider we already resolved,
      # strip it so ruby_llm resolves the native provider. A non-matching prefix
      # (a genuine aggregator id whose vendor differs from the resolved provider)
      # is left untouched. The *_compatible / assume_model_exists paths pass an
      # explicit provider to RubyLLM.chat, so they never reach this ambiguity and
      # keep the raw id verbatim.
      def chat_model_id
        id = @model_id.to_s
        return @model_id unless id.include?("/")

        prefix, remainder = id.split("/", 2)
        return @model_id if remainder.strip.empty?
        return remainder if ProviderResolver.resolve(prefix) == @provider

        @model_id
      end

      # Applies the request-shaping knobs ruby_llm 1.15 supports — temperature,
      # max_tokens, and a thinking/reasoning budget — onto the chat instance.
      # The render rules (enable manual thinking with a budget, force temp=1,
      # raise max_tokens to fit budget + headroom) are a faithful port of the
      # reference and live in LLM::ReasoningManager — the
      # single source of truth for the wire shape. This method only RESOLVES the
      # config inputs (which path, budget, ceiling, headroom, configured temp)
      # and APPLIES the manager's rendered params onto the chat.
      #
      # Why max_tokens matters for MiniMax-M2.7: ruby_llm's anthropic provider
      # defaults max_tokens to 4096 (Anthropic::Chat#build_base_payload:
      # `model.max_tokens || 4096`), and with assume_model_exists the model
      # carries no max_tokens — so a reasoning model can burn the whole 4096 on
      # thinking tokens and return ZERO visible text (the "completed but empty"
      # symptom). The manager raises the ceiling so it has room to think AND
      # answer. Thinking + the aggressive ceiling are Anthropic-Messages concepts
      # only safe on the anthropic-family path; for openai/ollama/etc. we leave
      # token limits to the provider (apply_max_tokens: false) and only apply
      # temperature.
      def apply_generation_params(chat)
        anthropic_family = anthropic_generation_path?

        rendered = reasoning_manager.render(
          budget: anthropic_family ? thinking_budget : 0,
          temperature: @temperature,
          max_tokens: max_output_tokens,
          text_headroom: text_headroom_tokens,
          apply_max_tokens: anthropic_family
        )

        params = { max_tokens: rendered.max_tokens }.compact

        if rendered.thinking_enabled?
          if ThinkingSupport.budget_via_params?(provider_cfg, chat)
            params[:thinking] = rendered.thinking
          elsif chat.respond_to?(:with_thinking)
            chat.with_thinking(budget: rendered.thinking[:budget_tokens])
          end
        end
        chat.with_temperature(rendered.temperature) if !rendered.temperature.nil? && chat.respond_to?(:with_temperature)
        # Single with_params call — ruby_llm REPLACES @params on every call,
        # so max_tokens and a params-routed thinking block must travel together.
        chat.with_params(**params) if params.any? && chat.respond_to?(:with_params)
      end

      def reasoning_manager = @reasoning_manager ||= ReasoningManager.new

      # True when generation runs through ruby_llm's anthropic provider — the
      # only path where thinking budgets and the 4096 max_tokens default apply.
      def anthropic_generation_path?
        anthropic_compatible_provider? ||
          %w[anthropic bedrock].include?(@provider.to_s)
      end

      # True when the tool block should carry an Anthropic prompt-cache
      # breakpoint (#311): the anthropic-family path AND prompt caching enabled
      # in config (prompts.prompt_cache, default on). cache_control is an
      # Anthropic concept, so we never emit it on the openai path.
      def tool_cache_breakpoint?
        return false unless anthropic_generation_path?

        value = @config.dig("prompts", "prompt_cache")
        value.nil? || value == true
      rescue StandardError
        false
      end

      # Configurable max output tokens. providers.<name>.max_tokens wins, then
      # model.max_tokens, then a reasoning-model-sane default (16k vs ruby_llm's
      # 4096). Returns an Integer.
      def max_output_tokens
        (provider_cfg["max_tokens"] ||
         @config.dig("model", "max_tokens") ||
         16_384).to_i
      end

      # Thinking/reasoning budget in tokens. 0 / nil disables thinking entirely.
      # thinking.effort wins when set (off→0, low→4000, medium→8000, high→16000);
      # otherwise providers.<name>.thinking_budget, then model.thinking_budget,
      # then a medium default (8000 — the same value the reference THINKING_BUDGET
      # maps "medium" to). Only meaningful for the anthropic-compatible path;
      # other providers ignore with_thinking or never see it (we still set it,
      # ruby_llm only renders thinking for providers that support it).
      def thinking_budget
        # A provider that rejected the budget earlier this session never gets
        # sent one again (#75).
        return 0 if ThinkingSupport.unsupported?(@provider)
        # A provider configured/known to mishandle an ACCEPTED budget never
        # gets sent one at all (#2) — capability beats the requested effort.
        return 0 unless ThinkingSupport.supports?(provider_cfg, @model_id)

        effort = Config::ReasoningPrefs.effort(@config)
        return Config::ReasoningPrefs.effort_budget(effort).to_i if effort

        raw = provider_cfg.key?("thinking_budget") ? provider_cfg["thinking_budget"] : nil
        raw = @config.dig("model", "thinking_budget") if raw.nil?
        raw = 8000 if raw.nil?
        raw.to_i
      end

      # Headroom (tokens) reserved for visible output on top of the thinking
      # budget, so the model can think AND still answer. Mirrors the reference +4096.
      def text_headroom_tokens
        (@config.dig("model", "max_tokens_text_headroom") || 4096).to_i
      end

      # Returns true when using Bedrock Bearer token (short-term API key, no secret)
      def bedrock_bearer_mode?
        %w[bedrock anthropic].include?(@provider) &&
          ENV.fetch("BEDROCK_API_KEY", nil) && !ENV["BEDROCK_SECRET_KEY"]
      end

      # Provider config hash from the config file (e.g. providers.ollama.*)
      # The RUBYLLM_DEBUG log path, under the resolved home (RUBINO_HOME ->
      # else ~/.rubino) so an isolated/custom home is not polluted with a log
      # written into the default ~/.rubino (issue #27).
      def debug_log_path
        File.join(Rubino::Config::Loader.default_home_path, "logs", "ruby_llm.log")
      end

      def provider_cfg
        @config.provider_config(@provider)
      end

      # True when the provider declares openai_compatible: true in config.
      # Used for ollama, lm-studio, vllm, text-generation-webui, etc.
      def openai_compatible_provider?
        provider_cfg["openai_compatible"] == true
      end

      # True when the provider declares anthropic_compatible: true in config.
      # Routes through ruby_llm's anthropic provider against a custom base_url
      # (e.g. MiniMax's native Anthropic-Messages endpoint).
      def anthropic_compatible_provider?
        provider_cfg["anthropic_compatible"] == true
      end

      # True when ruby_llm supports `provider` natively via a `<provider>_api_key`
      # config setter (deepseek, mistral, perplexity, xai, …) AND we don't already
      # special-case it (openai/anthropic/gemini/bedrock have dedicated wiring).
      # Single source of truth shared with CredentialCheck so the preflight only
      # promises "usable" for a provider whose key the adapter actually wires (#482).
      def native_ruby_llm_provider?(provider)
        CredentialCheck.native_ruby_llm_provider?(provider)
      end

      # True when the "hidden" render mode is active. The streaming emit no
      # longer drops :thinking chunks on it — the CLI buffers them unrendered
      # so Ctrl-O can reveal the last thought even in hidden mode (#76), and
      # UI::API drops them at its own boundary. Still gates the bedrock-bearer
      # client, which has no downstream reveal machinery.
      def reasoning_hidden?
        Config::ReasoningPrefs.effective_mode(@config) == :hidden
      end

      # ── Streaming resilience helpers (issues #12, #22) ────────────────────
      #
      # NOTE: error-classification, backoff and api_max_retries retries moved to
      # Agent::ModelCallRunner (Slice 4) — the single retry owner. The adapter no
      # longer wraps calls in a retry loop; it only RAISES retryable errors (and
      # pre-first-chunk stream drops) straight through for the runner to retry.

      def monotonic_now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      def stale_chunk_timeout
        explicit = @config.dig("providers", @provider, "stale_timeout_seconds")
        return explicit if explicit

        return 30 if openai_compatible_provider? || anthropic_compatible_provider?

        @config.dig("providers", "openai", "stale_timeout_seconds") || 300
      end

      def check_stream_stale!(last_chunk_at, stale_after)
        return if stale_after.to_f <= 0
        return if (monotonic_now - last_chunk_at) <= stale_after

        raise StreamStaleError, "no chunk received for #{stale_after}s"
      end

      # Watchdog that bounds a STALLED stream independent of chunk arrival
      # (#360): the per-chunk check_stream_stale! cannot fire once chunks stop,
      # so a stream that opens then goes silent would otherwise block on the
      # blocking socket read until the 600s read-timeout. This thread wakes on
      # short ticks, recomputes the idle gap from the live `last_chunk_at`
      # (read via the given block each tick), and on observing an idle past
      # `stale_after` raises StreamStaleError INTO the streaming thread to break
      # it out of the read. nil when stale_after <= 0 (watchdog disabled).
      def start_stale_watchdog(stale_after, &last_chunk_at_reader)
        return if stale_after.to_f <= 0

        target = Thread.current
        # Tick fast enough to bound the OVERSHOOT past the deadline, but never
        # busy-spin: cap the tick at 1s and never exceed the deadline itself.
        tick = (stale_after.to_f / 4.0).clamp(0.01, 1.0)
        Thread.new do
          loop do
            sleep(tick)
            if @cancel_token&.cancelled?
              target.raise(Rubino::Interrupted.new(reason: @cancel_token.reason))
              break
            end

            idle = monotonic_now - last_chunk_at_reader.call
            next if idle <= stale_after

            target.raise(StreamStaleError.new("no chunk received for #{stale_after}s"))
            break
          end
        end
      end

      def stop_stale_watchdog(watchdog)
        return unless watchdog

        watchdog.kill
        watchdog.join
      rescue StandardError
        nil
      end

      def log_safely(**fields)
        Rubino.logger.warn(**fields)
      rescue StandardError
        # Logger may be uninitialized during early boot — swallow.
      end

      # Returns a memoized BedrockBearerClient instance
      def bedrock_bearer_client
        @bedrock_bearer_client ||= BedrockBearerClient.new(
          api_key: ENV.fetch("BEDROCK_API_KEY", nil),
          region: ENV["BEDROCK_REGION"] || "us-east-1",
          model_id: @model_id,
          show_reasoning: !reasoning_hidden?,
          event_bus: @event_bus
        )
      end

      # Returns the content of the last message
      def last_user_content(messages)
        last = messages.last
        last[:content] || last["content"]
      end

      # ruby_llm's `with:` treats [] as "build a Content with no attachments"
      # which is technically valid but pointless — pass nil so it skips the
      # Content wrapper entirely.
      def presence(arr)
        arr.nil? || arr.empty? ? nil : arr
      end

      # Loads conversation history into the chat instance, excluding the last message.
      #
      # Tool result messages MUST carry their tool_call_id when reconstructed —
      # Anthropic and Bedrock validate that every tool message's id matches a
      # preceding assistant toolUse block, and reject the request with a 400
      # otherwise. The DB already stores the id (Session::Message#to_context
      # provides it); previously it was dropped on the floor here.
      def load_history(chat_instance, messages)
        history = messages[0..-2]
        return if history.empty?

        history.each do |msg|
          role         = (msg[:role] || msg["role"]).to_sym
          content      = msg[:content] || msg["content"]
          tool_calls   = rebuild_tool_calls(msg[:tool_calls] || msg["tool_calls"]) if role == :assistant
          # A Content::Raw (the #311 prompt-cache system block) is a structured
          # provider payload, not a String — it has no #empty?. Treat it as
          # always-present; only String/nil content is empty-checked.
          #
          # An assistant row that carries tool_calls MUST NOT be skipped even
          # when its text content is empty — MiniMax/Anthropic narrate-then-call
          # (or call with no preamble), persisting an assistant row with empty
          # text but live tool_calls. Dropping it orphans the following tool
          # result row (tool_call_id with no matching tool_use) → provider 400
          # on the next completion (#370).
          empty_content = content.nil? || (content.respond_to?(:empty?) && content.empty?)
          next if empty_content && !(role == :assistant && tool_calls && !tool_calls.empty?)

          case role
          when :system
            chat_instance.with_instructions(content, append: true)
          when :user
            chat_instance.messages << RubyLLM::Message.new(role: role, content: content)
          when :assistant
            chat_instance.messages << RubyLLM::Message.new(
              role: role,
              content: content,
              tool_calls: tool_calls
            )
          when :tool
            chat_instance.messages << RubyLLM::Message.new(
              role: role,
              content: content,
              tool_call_id: msg[:tool_call_id] || msg["tool_call_id"]
            )
          end
        end
      end

      # Prefill-to-continue (Slice 5, rung 4): seat the model's own interim text
      # as a TRAILING assistant message so the next completion continues from it
      # instead of starting a fresh turn. The spike confirmed ruby_llm honours a
      # trailing assistant message on the /anthropic path (Anthropic's native
      # "assistant turn prefill"): the response stream picks up where the seed
      # left off, so a thinking-only model is pushed into visible content.
      #
      # No-op when the seed is blank — an empty prefill would add a degenerate
      # empty assistant turn that strict providers reject, so we skip it and let
      # the call behave as a plain re-issue.
      def apply_prefill(chat_instance, prefill)
        seed = prefill.to_s
        return if seed.strip.empty?

        chat_instance.messages << RubyLLM::Message.new(role: :assistant, content: seed)
      end

      # Reconstructs RubyLLM::ToolCall objects from the hashes persisted under
      # assistant message metadata. Returns nil for empty/missing input so
      # RubyLLM::Message treats it as a plain assistant turn.
      #
      # MUST return a Hash keyed by tool_call id ({ id => RubyLLM::ToolCall }),
      # NOT an Array — that is the shape every ruby_llm provider produces
      # (see anthropic/tools.rb#parse_tool_calls) and the shape its formatter
      # consumes via `msg.tool_calls.each_value` (anthropic/chat.rb:176). An
      # Array here raises `undefined method 'each_value' for Array` on the next
      # completion after a resume (#370).
      def rebuild_tool_calls(raw)
        return nil if raw.nil? || (raw.respond_to?(:empty?) && raw.empty?)

        Array(raw).each_with_object({}) do |tc, acc|
          h = tc.is_a?(Hash) ? tc.transform_keys(&:to_sym) : tc
          call = RubyLLM::ToolCall.new(
            id: h[:id],
            name: h[:name],
            arguments: h[:arguments] || {}
          )
          acc[call.id] = call
        end
      end

      # +buffered+ (streaming path) is every assistant TEXT block of the turn
      # concatenated, not just the final one. ruby_llm runs tools mid-stream and
      # returns a response whose #content is only the LAST block, so any text the
      # model narrated BEFORE a tool call (block 1 in text→tool_use→text) would
      # be dropped from the headless output and the persisted transcript (#261).
      # Prefer the buffer when present; it's already been streamed to the live
      # UI chunk-by-chunk, so using it here re-persists, never re-renders.
      #
      # +usage+, when present (the round-trip accumulator from
      # wire_round_trip_callbacks), reports the SUMMED input/output tokens across
      # EVERY assistant message of the turn — so a multi-round-trip streaming turn
      # bills its true spend, not just the final message (#355b). Falls back to
      # the final response's own usage when no accumulator was wired (the
      # accumulator is only zero when ruby_llm surfaced no per-message usage, in
      # which case the final-message usage is the best we have).
      def build_response(response, buffered = nil, usage: nil, final_text_block: nil, streaming: false)
        return nil unless response

        # Budget Halt (#355a): when ToolBridge returned RubyLLM::Tool::Halt to
        # stop the in-ask loop, ruby_llm's handle_tool_calls returns the Halt
        # itself (not a Message). It exposes no usage/tool_calls, so build a
        # response from the buffered streamed text (the preamble the user already
        # saw) with NO tool calls and the summed usage — the Loop then runs its
        # budget-exhausted summary. content_for_halt prefers the buffer; the Halt
        # content is the internal nudge, not user-facing answer text.
        if response.is_a?(::RubyLLM::Tool::Halt)
          summed_in, summed_out = usage ? [usage[:input].to_i, usage[:output].to_i] : [0, 0]
          return AdapterResponse.new(
            content: buffered.to_s,
            tool_calls: [],
            input_tokens: summed_in,
            output_tokens: summed_out,
            model_id: @model_id,
            halted: true,
            raw: response
          )
        end

        input_tokens, output_tokens = summed_usage(response, usage)

        AdapterResponse.new(
          content: buffered && !buffered.empty? ? buffered : response.content,
          # On the streaming path ruby_llm runs the WHOLE model↔tool loop inside
          # one ask(): every tool was already executed mid-stream via ToolBridge
          # (→ Agent::ToolExecutor — the single source of truth for the
          # tool_started/tool_finished render + audit). The message ruby_llm
          # RETURNS, however, can STILL carry those executed tool_calls (the
          # anthropic-compatible MiniMax /anthropic path does), and handing them
          # back made Loop#run's #has_tool_calls? branch re-run #execute_tool_calls
          # on tools that already ran — firing a SECOND tool_finished and rendering
          # the `└ ▸ sa_… · <name> · started` spawn confirmation TWICE (#53). They
          # already ran, so the streaming response carries NONE; the Loop treats it
          # as the terminal text turn. The non-streaming path keeps them: there
          # ruby_llm returns the final TEXT message (no tool_calls) anyway.
          tool_calls: streaming ? [] : extract_tool_calls(response),
          input_tokens: input_tokens,
          output_tokens: output_tokens,
          model_id: @model_id,
          stop_reason: extract_stop_reason(response),
          thinking: extract_thinking(response),
          cache_read_tokens: cache_token(response, :cache_read_tokens),
          cache_creation_tokens: cache_token(response, :cache_creation_tokens),
          # The isolated final text block (#core-F1). Only meaningful when it
          # differs from the full buffer (a multi-block turn that ended after a
          # tool call); nil ⇒ AdapterResponse#final_text_block falls back to
          # content, so single-block and non-streaming turns are unchanged.
          final_text_block: final_block_for(final_text_block, buffered),
          raw: response
        )
      end

      # Returns the final-block text to carry on the response, or nil when it adds
      # nothing over the full buffer (single block, or no boundary tracked) so the
      # response falls back to +content+. Guards against a falsely-narrow answer:
      # only narrows when the captured last block is a non-empty STRICT suffix of
      # the buffer (i.e. earlier blocks really were dropped).
      def final_block_for(last_block, buffered)
        return nil if last_block.nil? || buffered.nil?

        lb = last_block.to_s
        return nil if lb.empty? || lb == buffered
        return nil unless buffered.end_with?(lb)

        lb
      end

      # Resolves the [input, output] token pair build_response reports. Prefers
      # the per-round-trip accumulator (the WHOLE turn's spend, #355b); falls back
      # to the final response's own usage when the accumulator saw no per-message
      # usage (a provider/path that doesn't surface it) so single-call turns are
      # unchanged.
      def summed_usage(response, usage)
        return [response.input_tokens, response.output_tokens] if usage.nil?

        summed_in  = usage[:input].to_i
        summed_out = usage[:output].to_i
        return [response.input_tokens, response.output_tokens] if summed_in.zero? && summed_out.zero?

        [summed_in, summed_out]
      end

      # Prompt-cache counter (#311) RubyLLM surfaces on the response message
      # (cache_read_tokens / cache_creation_tokens, from the Anthropic
      # cache_read_input_tokens / cache_creation_input_tokens usage fields).
      # Defaults to 0 on any path/provider that doesn't report it.
      def cache_token(response, reader)
        return 0 unless response.respond_to?(reader)

        response.public_send(reader).to_i
      rescue StandardError
        0
      end

      # Normalize the provider's finish/stop reason to the boundary's
      # :stop | :length | :tool_calls | nil vocabulary. Anthropic-compat (the
      # MiniMax /anthropic path) carries it in the raw body as "stop_reason"
      # ("end_turn"/"stop_sequence" ⇒ :stop, "max_tokens" ⇒ :length,
      # "tool_use" ⇒ :tool_calls); OpenAI-style carries "finish_reason"
      # ("stop" ⇒ :stop, "length" ⇒ :length, "tool_calls" ⇒ :tool_calls).
      # Returns nil when unreachable on this path — never fabricated. The
      # streaming path generally does not surface a stop reason on ruby_llm
      # today (see the boundary spike), so this stays nil there.
      def extract_stop_reason(response)
        body = raw_body(response)
        return nil unless body.is_a?(Hash)

        normalize_stop_reason(body["stop_reason"] || body["finish_reason"])
      end

      def normalize_stop_reason(reason)
        case reason.to_s
        when "end_turn", "stop_sequence", "stop" then :stop
        when "max_tokens", "length"              then :length
        when "tool_use", "tool_calls"            then :tool_calls
        end
      end

      # The raw Anthropic/OpenAI response body hash, when ruby_llm exposes it
      # (response.raw is a Faraday::Response; .body is the parsed JSON). nil on
      # paths where it is unreachable (streaming, doubles, bedrock-bearer).
      def raw_body(response)
        return nil unless response.respond_to?(:raw) && response.raw
        return nil unless response.raw.respond_to?(:body)

        response.raw.body
      rescue StandardError
        nil
      end

      # Reasoning text/summary if ruby_llm surfaced it on the message; nil
      # otherwise. Kept defensive — older builds carry no reasoning field.
      def extract_thinking(response)
        return nil unless response.respond_to?(:reasoning) && response.reasoning

        r = response.reasoning
        r.respond_to?(:text) ? r.text : r.to_s
      rescue StandardError
        nil
      end

      def extract_tool_calls(response)
        return [] unless response.respond_to?(:tool_calls) && response.tool_calls

        response.tool_calls.map do |tc|
          {
            id: tc.id,
            name: tc.name,
            arguments: tc.arguments
          }
        end
      end
    end
  end
end
