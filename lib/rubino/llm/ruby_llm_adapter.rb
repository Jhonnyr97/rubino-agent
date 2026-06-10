# frozen_string_literal: true

require "ruby_llm"
require "faraday"
require "net/http"
require_relative "tool_bridge"
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
        @model_id      = model_id || @config.model_default
        @provider      = provider || resolve_provider
        @temperature   = @config.model_temperature
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
      def chat(messages:, tools: nil, response_format: nil, image_paths: [], prefill: nil)
        if bedrock_bearer_mode?
          bedrock_bearer_client.chat(messages: messages, tools: tools)
        else
          chat_instance = build_chat(tools: tools, response_format: response_format)
          load_history(chat_instance, messages)
          apply_prefill(chat_instance, prefill)
          response = chat_instance.ask(last_user_content(messages), with: presence(image_paths))
          build_response(response)
        end
      end

      # Sends a streaming chat request, yielding chunks. Inline <think>…</think>
      # sentinels are routed to the :thinking channel. Buffered partial content
      # is preserved across mid-stream parse errors so downstream code can show
      # whatever the model produced before the failure.
      def stream(messages:, tools: nil, response_format: nil, image_paths: [], prefill: nil, &)
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
                    image_paths: image_paths, prefill: prefill, &)
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
        return @config.model_context_length if @config.model_context_length

        info&.context_window || 128_000
      end

      private

      # The raw #call dispatch (streaming vs non-streaming), shared by the
      # normal path and the one-shot thinking-budget retry (#75).
      def dispatch(request, &)
        if request.stream?
          stream(messages: request.messages, tools: request.tools,
                 image_paths: request.image_paths, prefill: request.prefill, &)
        else
          chat(messages: request.messages, tools: request.tools,
               image_paths: request.image_paths, prefill: request.prefill)
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
      def stream_once(messages:, tools:, response_format:, image_paths:, prefill: nil, &block)
        chat_instance = build_chat(tools: tools, response_format: response_format)
        load_history(chat_instance, messages)
        apply_prefill(chat_instance, prefill)

        think_filter  = InlineThinkFilter.new
        buffered      = +""
        last_chunk_at = monotonic_now
        stale_after   = stale_chunk_timeout
        chunks_seen   = 0

        # Each assistant message ruby_llm streams within this one ask() is a
        # distinct content block: on a multi-step tool turn the model emits
        # text → tool_use → (next message) text → … . We tag every content
        # delta with the current block's id so a consumer can regroup the
        # deltas that belong together instead of splitting them around the
        # tool calls that interleave mid-stream. before_message bumps the id;
        # after_message flushes the filter (so a buffered tail lands on THIS
        # block, before the tool fires) and emits the block boundary.
        message_block_id = 0

        emit = lambda do |type, text|
          next if text.nil? || text.empty?

          buffered << text if type == :content

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
        if chat_instance.respond_to?(:before_message)
          chat_instance.before_message { message_block_id += 1 }
        elsif chat_instance.respond_to?(:on_new_message)
          chat_instance.on_new_message { message_block_id += 1 }
        end

        close_block = proc do
          # Flush any tail the think-filter is still holding so it is emitted
          # with THIS block's id before we close the block (and before the
          # tool call that follows a tool-use message executes).
          flush_filter(think_filter, &emit)
          @event_bus&.emit(Interaction::Events::MESSAGE_COMPLETED, message_id: message_block_id)
        end
        if chat_instance.respond_to?(:after_message)
          chat_instance.after_message(&close_block)
        elsif chat_instance.respond_to?(:on_end_message)
          chat_instance.on_end_message(&close_block)
        end

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
        rescue JSON::ParserError, StreamStaleError => e
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
        end

        # Guard flush in the same way as the per-chunk emit so a final UI error
        # doesn't lose the response. (issue #21)
        flush_filter(think_filter, event: "llm.stream.flush_error", &emit)
        build_response(response)
      end

      # Flushes the think-filter, swallowing UI/flush errors so a late failure
      # never loses the response (issues #6, #21).
      def flush_filter(think_filter, event: "llm.stream.flush_error", &emit)
        think_filter.flush(&emit)
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
          c.openai_api_base = prov_cfg["base_url"] if prov_cfg["base_url"]
          c.openai_api_key  = openai_compatible_api_key!(prov_cfg)
        elsif anthropic_compatible_provider?
          c.anthropic_api_base = prov_cfg["base_url"] if prov_cfg["base_url"]
          c.anthropic_api_key  = anthropic_compatible_api_key!(prov_cfg)
        elsif @provider == "openai" && prov_cfg["base_url"]
          c.openai_api_base = prov_cfg["base_url"]
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

      # Resolution fallback for the direct-construction edge: AdapterFactory
      # always passes a concrete provider, so this only runs when the adapter is
      # built without one (tests, one-shot callers). Interpret the config
      # default — including "auto" and the Bedrock-bearer override — through the
      # single ProviderResolver seam rather than re-implementing it here.
      def resolve_provider
        ProviderResolver.resolve(@model_id, explicit_provider: @config.model_provider)
      end

      def build_chat(tools: nil, response_format: nil)
        options = { model: @model_id }
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

        # Register tools — ToolBridge wraps each Rubino tool so ruby_llm can
        # call it. When a ToolExecutor is available, execution goes through the
        # full pipeline (approval, truncation, audit recording). Otherwise the
        # bridge calls tool.call() directly (used in tests/one-shot mode).
        Array(tools).each do |tool|
          chat.with_tool(ToolBridge.for(tool, ui: @ui, event_bus: @event_bus,
                                              tool_executor: @tool_executor))
        end

        chat
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
      #
      # ruby_llm wiring confirmed on 1.15:
      #   * with_temperature(t)        -> payload[:temperature]               (anthropic/chat.rb add_optional_fields)
      #   * with_params(max_tokens: n) -> deep-merged over payload[:max_tokens] (provider.rb#complete)
      #   * with_thinking(budget: n)   -> payload[:thinking] = {type:"enabled",
      #                                     budget_tokens:n}                   (anthropic/chat.rb build_thinking_payload)
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

      # True when the "hidden" render mode is active. The streaming emit no
      # longer drops :thinking chunks on it — the CLI buffers them unrendered
      # so Ctrl-O can reveal the last thought even in hidden mode (#76), and
      # UI::API drops them at its own boundary. Still gates the bedrock-bearer
      # client, which has no downstream reveal machinery.
      def reasoning_hidden?
        Config::ReasoningPrefs.mode(@config) == :hidden
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
        @config.dig("providers", @provider, "stale_timeout_seconds") ||
          @config.dig("providers", "openai", "stale_timeout_seconds") ||
          300
      end

      def check_stream_stale!(last_chunk_at, stale_after)
        return if stale_after.to_i <= 0
        return if (monotonic_now - last_chunk_at) <= stale_after

        raise StreamStaleError, "no chunk received for #{stale_after}s"
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
          role    = (msg[:role] || msg["role"]).to_sym
          content = msg[:content] || msg["content"]
          next if content.nil? || content.empty?

          case role
          when :system
            chat_instance.with_instructions(content, append: true)
          when :user
            chat_instance.messages << RubyLLM::Message.new(role: role, content: content)
          when :assistant
            chat_instance.messages << RubyLLM::Message.new(
              role: role,
              content: content,
              tool_calls: rebuild_tool_calls(msg[:tool_calls] || msg["tool_calls"])
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
      def rebuild_tool_calls(raw)
        return nil if raw.nil? || (raw.respond_to?(:empty?) && raw.empty?)

        Array(raw).map do |tc|
          h = tc.transform_keys(&:to_sym) if tc.is_a?(Hash)
          h ||= tc
          RubyLLM::ToolCall.new(
            id: h[:id],
            name: h[:name],
            arguments: h[:arguments] || {}
          )
        end
      end

      def build_response(response)
        return nil unless response

        AdapterResponse.new(
          content: response.content,
          tool_calls: extract_tool_calls(response),
          input_tokens: response.input_tokens,
          output_tokens: response.output_tokens,
          model_id: @model_id,
          stop_reason: extract_stop_reason(response),
          thinking: extract_thinking(response),
          raw: response
        )
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
