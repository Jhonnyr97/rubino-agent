# frozen_string_literal: true

RSpec.describe Rubino::LLM::RubyLLMAdapter do
  let(:config) { test_configuration }

  # Reset RubyLLM global config between tests to avoid state leaking
  before do
    RubyLLM.configure do |c|
      c.anthropic_api_key  = nil
      c.anthropic_api_base = nil
      c.bedrock_api_key    = nil
      c.bedrock_secret_key = nil
      c.bedrock_region     = nil
      c.bedrock_session_token = nil
    end
    ENV.delete("BEDROCK_API_KEY")
    ENV.delete("BEDROCK_SECRET_KEY")
    ENV.delete("BEDROCK_SESSION_TOKEN")
    ENV.delete("BEDROCK_REGION")
  end

  # -----------------------------------------------------------------------
  # AdapterResponse
  # -----------------------------------------------------------------------

  describe Rubino::LLM::AdapterResponse do
    subject(:response) do
      described_class.new(
        content: "Hello!",
        tool_calls: [],
        input_tokens: 10,
        output_tokens: 5,
        model_id: "gpt-4o"
      )
    end

    it "exposes content" do
      expect(response.content).to eq("Hello!")
    end

    it "calculates total_tokens" do
      expect(response.total_tokens).to eq(15)
    end

    it "returns text_only? true when no tool calls" do
      expect(response.text_only?).to be true
    end

    it "returns has_tool_calls? false when empty" do
      expect(response.has_tool_calls?).to be false
    end

    context "with tool calls" do
      subject(:response) do
        described_class.new(
          content: nil,
          tool_calls: [{ id: "call_1", name: "read_file", arguments: { path: "foo.rb" } }],
          input_tokens: 20,
          output_tokens: 10,
          model_id: "gpt-4o"
        )
      end

      it "returns has_tool_calls? true" do
        expect(response.has_tool_calls?).to be true
      end

      it "returns text_only? false" do
        expect(response.text_only?).to be false
      end
    end

    context "with nil content and no tool calls" do
      subject(:response) do
        described_class.new(
          content: nil,
          tool_calls: [],
          input_tokens: 5,
          output_tokens: 0,
          model_id: "gpt-4o"
        )
      end

      it "returns text_only? false" do
        expect(response.text_only?).to be false
      end
    end

    it "defaults tool_calls to empty array when nil" do
      r = described_class.new(
        content: "hi", tool_calls: nil,
        input_tokens: 1, output_tokens: 1, model_id: "gpt-4o"
      )
      expect(r.tool_calls).to eq([])
    end

    # --- normalized boundary fields -------------------
    # These default nil-safely so existing callers that pass only the core
    # fields keep working unchanged.
    context "normalized boundary fields default nil-safely" do
      subject(:bare) do
        described_class.new(content: "hi", tool_calls: [],
                            input_tokens: 1, output_tokens: 2, model_id: "m")
      end

      it "defaults thinking to nil" do
        expect(bare.thinking).to be_nil
      end

      it "defaults stop_reason to nil" do
        expect(bare.stop_reason).to be_nil
      end

      it "defaults raw to nil" do
        expect(bare.raw).to be_nil
      end

      it "exposes usage as a nil-safe token hash (incl. #311 prompt-cache counters)" do
        expect(bare.usage).to eq(input_tokens: 1, output_tokens: 2,
                                 cache_read_input_tokens: 0, cache_creation_input_tokens: 0)
      end

      it "zeroes usage when tokens are nil" do
        r = described_class.new(content: "hi", tool_calls: [],
                                input_tokens: nil, output_tokens: nil, model_id: "m")
        expect(r.usage).to eq(input_tokens: 0, output_tokens: 0,
                              cache_read_input_tokens: 0, cache_creation_input_tokens: 0)
      end
    end

    context "when the new fields are supplied" do
      subject(:full) do
        described_class.new(content: "answer", tool_calls: [],
                            input_tokens: 3, output_tokens: 4, model_id: "m",
                            thinking: "let me think", stop_reason: :length,
                            raw: { some: "body" })
      end

      it "carries thinking" do
        expect(full.thinking).to eq("let me think")
      end

      it "carries stop_reason" do
        expect(full.stop_reason).to eq(:length)
      end

      it "carries raw as an escape hatch" do
        expect(full.raw).to eq(some: "body")
      end

      it "keeps text_only? working unchanged" do
        expect(full.text_only?).to be true
      end
    end
  end

  # -----------------------------------------------------------------------
  # stop_reason mapping (Anthropic-compat / OpenAI-style body → boundary)
  # -----------------------------------------------------------------------

  describe "#normalize_stop_reason" do
    subject(:adapter) { described_class.new(model_id: "gpt-4o", config: config) }

    {
      "end_turn" => :stop,
      "stop_sequence" => :stop,
      "stop" => :stop,
      "max_tokens" => :length,
      "length" => :length,
      "tool_use" => :tool_calls,
      "tool_calls" => :tool_calls,
      "weird_reason" => nil,
      "" => nil,
      nil => nil
    }.each do |raw, expected|
      it "maps #{raw.inspect} → #{expected.inspect}" do
        expect(adapter.send(:normalize_stop_reason, raw)).to eq(expected)
      end
    end
  end

  describe "#extract_stop_reason (from a response body fixture)" do
    subject(:adapter) { described_class.new(model_id: "gpt-4o", config: config) }

    # Mimics ruby_llm's response.raw (a Faraday::Response) carrying a parsed
    # Anthropic-Messages body. We only depend on .raw.body, never provider types.
    def response_with_body(body)
      raw = Struct.new(:body).new(body)
      Struct.new(:raw).new(raw)
    end

    it "maps an Anthropic stop_reason from the body" do
      resp = response_with_body("stop_reason" => "max_tokens")
      expect(adapter.send(:extract_stop_reason, resp)).to eq(:length)
    end

    it "maps an OpenAI finish_reason from the body" do
      resp = response_with_body("finish_reason" => "tool_calls")
      expect(adapter.send(:extract_stop_reason, resp)).to eq(:tool_calls)
    end

    it "returns nil when the body has no stop/finish reason" do
      resp = response_with_body("foo" => "bar")
      expect(adapter.send(:extract_stop_reason, resp)).to be_nil
    end

    it "returns nil when raw is unreachable (e.g. streaming/double)" do
      bare = Object.new
      expect(adapter.send(:extract_stop_reason, bare)).to be_nil
    end
  end

  # -----------------------------------------------------------------------
  # resolve_provider (auto-detection without Bedrock credentials)
  # -----------------------------------------------------------------------

  describe "#provider (auto-detection)" do
    {
      "openai/gpt-4o" => "openai",
      "gpt-4.1" => "openai",
      "o3" => "openai",
      "o4-mini" => "openai",
      "anthropic/claude-3-5-sonnet" => "anthropic",
      "claude-sonnet-4-5" => "anthropic",
      "google/gemini-2.5-pro" => "google",
      "gemini-2.5-flash" => "google",
      "amazon.titan-text-express-v1" => "bedrock",
      "meta.llama3-70b-instruct-v1:0" => "bedrock",
      "mistral.mistral-7b-instruct-v0:2" => "bedrock",
      "cohere.command-r-plus-v1:0" => "bedrock",
      "ai21.j2-ultra-v1" => "bedrock"
    }.each do |model_id, expected_provider|
      it "resolves #{model_id} → #{expected_provider}" do
        adapter = described_class.new(model_id: model_id, config: config)
        expect(adapter.provider).to eq(expected_provider)
      end
    end

    # anthropic. prefix → bedrock when no BEDROCK_API_KEY (IAM mode)
    it "resolves anthropic.claude-sonnet-4-5 → bedrock when no Bedrock credentials" do
      adapter = described_class.new(model_id: "anthropic.claude-sonnet-4-5", config: config)
      expect(adapter.provider).to eq("bedrock")
    end

    it "falls back to openai for unknown model" do
      adapter = described_class.new(model_id: "unknown-model-xyz", config: config)
      expect(adapter.provider).to eq("openai")
    end
  end

  describe "#provider with explicit config" do
    it "respects explicit provider in config" do
      cfg = test_configuration("model" => { "provider" => "anthropic",
                                            "default" => "gpt-4o",
                                            "temperature" => 0.3,
                                            "context_length" => nil })
      adapter = described_class.new(model_id: "gpt-4o", config: cfg)
      expect(adapter.provider).to eq("anthropic")
    end

    it "uses auto-detection when provider is 'auto'" do
      cfg = test_configuration("model" => { "provider" => "auto",
                                            "default" => "claude-sonnet-4-5",
                                            "temperature" => 0.3,
                                            "context_length" => nil })
      adapter = described_class.new(model_id: "claude-sonnet-4-5", config: cfg)
      expect(adapter.provider).to eq("anthropic")
    end
  end

  # -----------------------------------------------------------------------
  # Bedrock Mode 1: Bearer token (no secret key)
  # -----------------------------------------------------------------------

  describe "Bedrock Mode 1: Bearer token" do
    before do
      ENV["BEDROCK_API_KEY"] = "test-bearer-token"
      ENV["BEDROCK_REGION"]  = "eu-west-1"
    end

    after do
      ENV.delete("BEDROCK_API_KEY")
      ENV.delete("BEDROCK_REGION")
    end

    it "resolves provider as anthropic" do
      adapter = described_class.new(model_id: "us.anthropic.claude-sonnet-4-20250514-v1:0", config: config)
      expect(adapter.provider).to eq("anthropic")
    end

    it "respects explicit provider: bedrock in config (bearer client handles routing)" do
      cfg = test_configuration("model" => { "provider" => "bedrock",
                                            "default" => "us.anthropic.claude-sonnet-4-20250514-v1:0",
                                            "temperature" => 0.3,
                                            "context_length" => nil })
      adapter = described_class.new(model_id: "us.anthropic.claude-sonnet-4-20250514-v1:0", config: cfg)
      expect(adapter.provider).to eq("bedrock")
      expect(adapter.send(:bedrock_bearer_mode?)).to be true
    end

    it "activates bedrock_bearer_mode?" do
      adapter = described_class.new(model_id: "us.anthropic.claude-sonnet-4-20250514-v1:0", config: config)
      expect(adapter.send(:bedrock_bearer_mode?)).to be true
    end

    it "does NOT activate bedrock_bearer_mode? when no key" do
      ENV.delete("BEDROCK_API_KEY")
      adapter = described_class.new(model_id: "gpt-4o", config: config)
      expect(adapter.send(:bedrock_bearer_mode?)).to be_falsey
    end

    it "builds BedrockBearerClient with correct region" do
      adapter = described_class.new(model_id: "us.anthropic.claude-sonnet-4-20250514-v1:0", config: config)
      client = adapter.send(:bedrock_bearer_client)
      expect(client).to be_a(Rubino::LLM::BedrockBearerClient)
      expect(client.instance_variable_get(:@region)).to eq("eu-west-1")
    end

    it "builds BedrockBearerClient with default region us-east-1" do
      ENV.delete("BEDROCK_REGION")
      adapter = described_class.new(model_id: "us.anthropic.claude-sonnet-4-20250514-v1:0", config: config)
      client = adapter.send(:bedrock_bearer_client)
      expect(client.instance_variable_get(:@region)).to eq("us-east-1")
    end

    it "does not set bedrock_secret_key in ruby_llm config" do
      described_class.new(model_id: "us.anthropic.claude-sonnet-4-20250514-v1:0", config: config)
      expect(RubyLLM.config.bedrock_secret_key).to be_nil
    end

    it "does not set anthropic_api_base in ruby_llm config" do
      described_class.new(model_id: "us.anthropic.claude-sonnet-4-20250514-v1:0", config: config)
      expect(RubyLLM.config.anthropic_api_base).to be_nil
    end
  end

  # -----------------------------------------------------------------------
  # SLICE-7: per-call config isolation (RubyLLM::Context)
  # A fallback adapter built with isolate_config: true must NOT touch the
  # process-global RubyLLM.configure — that is the global-config hazard fix.
  # -----------------------------------------------------------------------
  describe "isolate_config (fallback path)" do
    let(:isolated_config) do
      test_configuration(
        "providers" => {
          "minimax" => {
            "anthropic_compatible" => true,
            "base_url" => "https://fallback.example/anthropic",
            "api_key" => "fallback-key"
          }
        }
      )
    end

    it "does NOT mutate the global anthropic_api_base when isolate_config: true" do
      expect(RubyLLM.config.anthropic_api_base).to be_nil
      described_class.new(model_id: "MiniMax-M2.7", provider: "minimax",
                          config: isolated_config, isolate_config: true)
      expect(RubyLLM.config.anthropic_api_base).to be_nil
    end

    it "DOES write the global when isolate_config is false (primary path, unchanged)" do
      described_class.new(model_id: "MiniMax-M2.7", provider: "minimax",
                          config: isolated_config)
      expect(RubyLLM.config.anthropic_api_base).to eq("https://fallback.example/anthropic")
    end
  end

  # -----------------------------------------------------------------------
  # Bedrock Mode 2: IAM credentials (access key + secret)
  # -----------------------------------------------------------------------

  describe "Bedrock Mode 2: IAM credentials" do
    before do
      ENV["BEDROCK_API_KEY"]    = "AKIAIOSFODNN7EXAMPLE"
      ENV["BEDROCK_SECRET_KEY"] = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
      ENV["BEDROCK_REGION"]     = "us-east-1"
    end

    after do
      ENV.delete("BEDROCK_API_KEY")
      ENV.delete("BEDROCK_SECRET_KEY")
      ENV.delete("BEDROCK_REGION")
    end

    it "sets bedrock_api_key" do
      described_class.new(model_id: "anthropic.claude-sonnet-4-5", config: config)
      expect(RubyLLM.config.bedrock_api_key).to eq("AKIAIOSFODNN7EXAMPLE")
    end

    it "sets bedrock_secret_key" do
      described_class.new(model_id: "anthropic.claude-sonnet-4-5", config: config)
      expect(RubyLLM.config.bedrock_secret_key).to eq("wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY")
    end

    it "sets bedrock_region" do
      described_class.new(model_id: "anthropic.claude-sonnet-4-5", config: config)
      expect(RubyLLM.config.bedrock_region).to eq("us-east-1")
    end

    it "does not set anthropic_api_base" do
      described_class.new(model_id: "anthropic.claude-sonnet-4-5", config: config)
      expect(RubyLLM.config.anthropic_api_base).to be_nil
    end

    it "does not set session token when BEDROCK_SESSION_TOKEN not present" do
      described_class.new(model_id: "anthropic.claude-sonnet-4-5", config: config)
      expect(RubyLLM.config.bedrock_session_token).to be_nil
    end
  end

  # -----------------------------------------------------------------------
  # Bedrock Mode 3: temporary credentials with session token
  # -----------------------------------------------------------------------

  describe "Bedrock Mode 3: temporary credentials" do
    before do
      ENV["BEDROCK_API_KEY"]       = "ASIAIOSFODNN7EXAMPLE"
      ENV["BEDROCK_SECRET_KEY"]    = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
      ENV["BEDROCK_SESSION_TOKEN"] = "AQoDYXdzEJr..."
      ENV["BEDROCK_REGION"]        = "us-west-2"
    end

    after do
      ENV.delete("BEDROCK_API_KEY")
      ENV.delete("BEDROCK_SECRET_KEY")
      ENV.delete("BEDROCK_SESSION_TOKEN")
      ENV.delete("BEDROCK_REGION")
    end

    it "sets bedrock_session_token" do
      described_class.new(model_id: "anthropic.claude-sonnet-4-5", config: config)
      expect(RubyLLM.config.bedrock_session_token).to eq("AQoDYXdzEJr...")
    end

    it "sets correct region" do
      described_class.new(model_id: "anthropic.claude-sonnet-4-5", config: config)
      expect(RubyLLM.config.bedrock_region).to eq("us-west-2")
    end
  end

  # -----------------------------------------------------------------------
  # No Bedrock credentials
  # -----------------------------------------------------------------------

  describe "without Bedrock credentials" do
    it "does not set bedrock_api_key" do
      described_class.new(model_id: "gpt-4o", config: config)
      expect(RubyLLM.config.bedrock_api_key).to be_nil
    end

    it "does not set anthropic_api_base" do
      described_class.new(model_id: "gpt-4o", config: config)
      expect(RubyLLM.config.anthropic_api_base).to be_nil
    end
  end

  # -----------------------------------------------------------------------
  # context_window
  # -----------------------------------------------------------------------

  describe "#context_window" do
    it "returns config override when set" do
      cfg = test_configuration("model" => { "context_length" => 32_000,
                                            "default" => "gpt-4o",
                                            "provider" => "auto",
                                            "temperature" => 0.3 })
      adapter = described_class.new(model_id: "gpt-4o", config: cfg)
      expect(adapter.context_window).to eq(32_000)
    end

    it "falls back to 128_000 when model info unavailable" do
      adapter = described_class.new(model_id: "unknown-model-xyz", config: config)
      allow(adapter).to receive(:model_info).and_return(nil)
      expect(adapter.context_window).to eq(128_000)
    end
  end

  # -----------------------------------------------------------------------
  # Audit fixes — provider auto-detect for reasoning models (#5)
  # -----------------------------------------------------------------------

  describe "#provider auto-detection for reasoning models (#5)" do
    {
      "MiniMax-M2" => "minimax",
      "abab6.5s-chat" => "minimax",
      "qwen2.5-72b" => "qwen",
      "deepseek-r1" => "deepseek"
    }.each do |model_id, expected|
      it "resolves #{model_id} → #{expected}" do
        adapter = described_class.new(model_id: model_id, config: config)
        expect(adapter.provider).to eq(expected)
      end
    end
  end

  # -----------------------------------------------------------------------
  # Audit fixes — openai_compatible api_key error (#3)
  # -----------------------------------------------------------------------

  describe "openai_compatible api_key validation (#3)" do
    it "raises a clear error when api_key is missing" do
      cfg = test_configuration(
        "model" => { "provider" => "ollama", "default" => "llama3", "temperature" => 0.3, "context_length" => nil },
        "providers" => { "ollama" => { "openai_compatible" => true, "base_url" => "http://localhost:11434/v1" } }
      )
      ENV.delete("OPENAI_API_KEY")
      expect do
        described_class.new(model_id: "llama3", config: cfg)
      end.to raise_error(Rubino::Error, /Missing API key for provider 'ollama'/)
    end

    it "accepts the api_key from provider config" do
      cfg = test_configuration(
        "model" => { "provider" => "ollama", "default" => "llama3", "temperature" => 0.3, "context_length" => nil },
        "providers" => { "ollama" => { "openai_compatible" => true, "api_key" => "sk-test", "base_url" => "http://x" } }
      )
      expect do
        described_class.new(model_id: "llama3", config: cfg)
      end.not_to raise_error
    end
  end

  # -----------------------------------------------------------------------
  # gateway provider — model name "auto" passthrough.
  # The /v1/* gateway rewrites the model upstream, so the agent
  # only needs to (a) skip model validation, (b) route as OpenAI-compat,
  # (c) point at the gateway base_url with the client api_key.
  # -----------------------------------------------------------------------

  describe "gateway provider" do
    let(:cfg) do
      test_configuration(
        "model" => { "provider" => "gateway", "default" => "auto",
                     "temperature" => 0.3, "context_length" => nil },
        "providers" => { "gateway" => {
          "openai_compatible" => true,
          "assume_model_exists" => true,
          "api_key" => "client_abc",
          "base_url" => "https://proxy.example.test/v1"
        } }
      )
    end

    it "resolves provider as gateway (no auto-detection on model id)" do
      adapter = described_class.new(model_id: "auto", config: cfg)
      expect(adapter.provider).to eq("gateway")
    end

    it "configures RubyLLM with the gateway base_url and tenant api_key" do
      captured = nil
      allow(RubyLLM).to receive(:configure).and_wrap_original do |orig, &blk|
        captured = double("rubyllm-config").as_null_object
        blk.call(captured)
        orig.call { |_| }
      end

      described_class.new(model_id: "auto", config: cfg)

      expect(captured).to have_received(:openai_api_base=).with("https://proxy.example.test/v1")
      expect(captured).to have_received(:openai_api_key=).with("client_abc")
    end

    it "passes model:auto + provider:openai + assume_model_exists to RubyLLM.chat" do
      adapter = described_class.new(model_id: "auto", config: cfg)
      expect(RubyLLM).to receive(:chat).with(
        hash_including(model: "auto", provider: :openai, assume_model_exists: true)
      ).and_return(double("chat", with_tool: nil))

      adapter.send(:build_chat)
    end
  end

  # -----------------------------------------------------------------------
  # anthropic_compatible provider — MiniMax native Anthropic-Messages endpoint.
  # Mirrors openai_compatible: route through ruby_llm's anthropic provider with
  # a custom base_url + api_key, assume_model_exists so an arbitrary model id is
  # accepted without a registry entry.
  # -----------------------------------------------------------------------

  describe "anthropic_compatible provider" do
    let(:cfg) do
      test_configuration(
        "model" => { "provider" => "minimax", "default" => "MiniMax-M2.7",
                     "temperature" => 0.3, "context_length" => nil },
        "providers" => { "minimax" => {
          "anthropic_compatible" => true,
          "assume_model_exists" => true,
          "api_key" => "mm_secret",
          "base_url" => "https://api.minimax.io/anthropic"
        } }
      )
    end

    it "configures RubyLLM with the anthropic base_url and provider api_key" do
      captured = nil
      allow(RubyLLM).to receive(:configure).and_wrap_original do |orig, &blk|
        captured = double("rubyllm-config").as_null_object
        blk.call(captured)
        orig.call { |_| }
      end

      described_class.new(model_id: "MiniMax-M2.7", config: cfg)

      expect(captured).to have_received(:anthropic_api_base=).with("https://api.minimax.io/anthropic")
      expect(captured).to have_received(:anthropic_api_key=).with("mm_secret")
    end

    it "passes provider:anthropic + assume_model_exists to RubyLLM.chat" do
      adapter = described_class.new(model_id: "MiniMax-M2.7", config: cfg)
      expect(RubyLLM).to receive(:chat).with(
        hash_including(model: "MiniMax-M2.7", provider: :anthropic, assume_model_exists: true)
      ).and_return(double("chat", with_tool: nil))

      adapter.send(:build_chat)
    end

    it "raises a clear error when api_key is missing" do
      bad = test_configuration(
        "model" => { "provider" => "minimax", "default" => "MiniMax-M2.7",
                     "temperature" => 0.3, "context_length" => nil },
        "providers" => { "minimax" => {
          "anthropic_compatible" => true,
          "base_url" => "https://api.minimax.io/anthropic"
        } }
      )
      ENV.delete("ANTHROPIC_API_KEY")
      expect do
        described_class.new(model_id: "MiniMax-M2.7", config: bad)
      end.to raise_error(Rubino::Error, /Missing API key for provider 'minimax'/)
    end
  end

  # -----------------------------------------------------------------------
  # Generation params: temperature + max_tokens + thinking. ruby_llm 1.15
  # supports with_temperature / with_params(max_tokens:) / with_thinking(budget:).
  # @temperature was read at init but never applied (dead config); a reasoning
  # model needs a raised max_tokens + a thinking budget or it exhausts the 4096
  # Anthropic default on thinking tokens and returns empty text.
  # -----------------------------------------------------------------------
  describe "#build_chat generation params" do
    # A chat double that records the request-shaping calls build_chat makes.
    def recording_chat
      c = double("chat")
      allow(c).to receive(:with_tool).and_return(c)
      allow(c).to receive(:with_temperature).and_return(c)
      allow(c).to receive(:with_params).and_return(c)
      allow(c).to receive(:with_thinking).and_return(c)
      c
    end

    context "anthropic-compatible provider (MiniMax-M2.7)" do
      let(:cfg) do
        # supports_thinking: true opts back into the budget — MiniMax-family
        # model ids default to no-thinking (#2); these specs exercise the
        # wire-shaping machinery, not the capability default.
        test_configuration(
          "model" => { "provider" => "minimax", "default" => "MiniMax-M2.7",
                       "temperature" => 0.3, "context_length" => nil },
          "providers" => { "minimax" => {
            "anthropic_compatible" => true, "assume_model_exists" => true,
            "api_key" => "mm_secret", "base_url" => "https://api.minimax.io/anthropic",
            "supports_thinking" => true
          } }
        )
      end
      let(:adapter) { described_class.new(model_id: "MiniMax-M2.7", config: cfg) }

      # supports_thinking: true on an assume-model-exists model routes the
      # thinking block through with_params (#175): ruby_llm 1.16's
      # with_thinking raises client-side for models whose registry entry
      # declares no budget_tokens reasoning option, so the documented opt-in
      # silently died (rejection detector → budget dropped for the session).
      it "enables thinking with the default budget (8000) via raw params" do
        chat = recording_chat
        allow(RubyLLM).to receive(:chat).and_return(chat)
        adapter.send(:build_chat)
        expect(chat).not_to have_received(:with_thinking)
        expect(chat).to have_received(:with_params)
          .with(hash_including(thinking: { type: :enabled, budget_tokens: 8000 }))
      end

      it "keeps with_thinking when the model's registry entry declares a budget option" do
        chat = recording_chat
        model = double("model", reasoning_option: { type: "budget_tokens" })
        allow(chat).to receive(:model).and_return(model)
        allow(RubyLLM).to receive(:chat).and_return(chat)
        adapter.send(:build_chat)
        expect(chat).to have_received(:with_thinking).with(budget: 8000)
        expect(chat).to have_received(:with_params).with(max_tokens: 16_384)
      end

      it "forces temperature=1 when thinking is enabled (Anthropic constraint)" do
        chat = recording_chat
        allow(RubyLLM).to receive(:chat).and_return(chat)
        adapter.send(:build_chat)
        expect(chat).to have_received(:with_temperature).with(1)
      end

      it "raises max_tokens to at least thinking budget + text headroom" do
        chat = recording_chat
        allow(RubyLLM).to receive(:chat).and_return(chat)
        adapter.send(:build_chat)
        # default ceiling 16384 vs budget(8000)+headroom(4096)=12096 → 16384.
        # Single with_params call: ruby_llm REPLACES @params on every call, so
        # max_tokens must ride together with the params-routed thinking block.
        expect(chat).to have_received(:with_params).once.with(hash_including(max_tokens: 16_384))
      end

      it "drives the wire params through LLM::ReasoningManager#render (single source of truth)" do
        chat = recording_chat
        allow(RubyLLM).to receive(:chat).and_return(chat)
        # The manager is the only place that decides the wire shape; the adapter
        # just applies what it renders. Spy on the manager to prove no duplicate
        # inline rendering remains in the adapter.
        rendered = Rubino::LLM::ReasoningManager::Rendered.new(
          thinking: { type: :enabled, budget_tokens: 8000 }, temperature: 1, max_tokens: 16_384
        )
        manager = instance_double(Rubino::LLM::ReasoningManager, render: rendered)
        allow(adapter).to receive(:reasoning_manager).and_return(manager)

        adapter.send(:build_chat)

        expect(manager).to have_received(:render).with(
          budget: 8000, temperature: 0.3, max_tokens: 16_384,
          text_headroom: 4096, apply_max_tokens: true
        )
        expect(chat).to have_received(:with_temperature).with(1)
        expect(chat).to have_received(:with_params)
          .with(max_tokens: 16_384, thinking: { type: :enabled, budget_tokens: 8000 })
      end

      it "honors a provider thinking_budget override and grows max_tokens accordingly" do
        c2 = test_configuration(
          "model" => { "provider" => "minimax", "default" => "MiniMax-M2.7",
                       "temperature" => 0.3, "context_length" => nil },
          "providers" => { "minimax" => {
            "anthropic_compatible" => true, "assume_model_exists" => true,
            "api_key" => "mm_secret", "base_url" => "https://api.minimax.io/anthropic",
            "thinking_budget" => 30_000, "supports_thinking" => true
          } }
        )
        a = described_class.new(model_id: "MiniMax-M2.7", config: c2)
        chat = recording_chat
        allow(RubyLLM).to receive(:chat).and_return(chat)
        a.send(:build_chat)
        # 30000 + 4096 = 34096 > default 16384
        expect(chat).to have_received(:with_params)
          .with(max_tokens: 34_096, thinking: { type: :enabled, budget_tokens: 30_000 })
      end

      it "applies @temperature (not forced 1) when thinking is disabled (budget 0)" do
        c3 = test_configuration(
          "model" => { "provider" => "minimax", "default" => "MiniMax-M2.7",
                       "temperature" => 0.3, "context_length" => nil },
          "providers" => { "minimax" => {
            "anthropic_compatible" => true, "assume_model_exists" => true,
            "api_key" => "mm_secret", "base_url" => "https://api.minimax.io/anthropic",
            "thinking_budget" => 0
          } }
        )
        a = described_class.new(model_id: "MiniMax-M2.7", config: c3)
        chat = recording_chat
        allow(RubyLLM).to receive(:chat).and_return(chat)
        a.send(:build_chat)
        expect(chat).not_to have_received(:with_thinking)
        expect(chat).to have_received(:with_temperature).with(0.3)
        # exact match — no thinking block rides along when the budget is off
        expect(chat).to have_received(:with_params).with(max_tokens: 16_384)
      end
    end

    context "openai provider (non-anthropic path)" do
      let(:cfg) do
        test_configuration("model" => { "provider" => "openai", "default" => "gpt-4o",
                                        "temperature" => 0.5, "context_length" => nil })
      end
      let(:adapter) { described_class.new(model_id: "gpt-4o", config: cfg) }

      it "applies temperature but does NOT enable thinking or force a max_tokens" do
        chat = recording_chat
        allow(RubyLLM).to receive(:chat).and_return(chat)
        adapter.send(:build_chat)
        expect(chat).to have_received(:with_temperature).with(0.5)
        expect(chat).not_to have_received(:with_thinking)
        expect(chat).not_to have_received(:with_params)
      end
    end
  end

  # -----------------------------------------------------------------------
  # Audit fixes — streaming resilience (#6, #21)
  # -----------------------------------------------------------------------

  describe "#stream resilience" do
    let(:chunk)    { double("Chunk", content: "hello", thinking: nil) }
    let(:response) { double("Response", content: "hello", input_tokens: 1, output_tokens: 1, tool_calls: nil) }
    let(:fake_chat) do
      c = double("Chat")
      allow(c).to receive(:with_tool).and_return(c)
      allow(c).to receive(:with_instructions).and_return(c)
      allow(c).to receive(:messages).and_return([])
      chunks = [chunk]
      r = response
      allow(c).to receive(:ask) do |_, &blk|
        chunks.each { |ch| blk.call(ch) }
        r
      end
      c
    end

    let(:adapter) do
      cfg = test_configuration(
        "model" => { "provider" => "openai", "default" => "gpt-4o", "temperature" => 0.3, "context_length" => nil }
      )
      a = described_class.new(model_id: "gpt-4o", config: cfg)
      allow(a).to receive(:build_chat).and_return(fake_chat)
      a
    end

    it "swallows errors in the user-supplied block instead of aborting the stream (#6)" do
      received_after_error = false
      expect do
        adapter.stream(messages: [{ role: "user", content: "hi" }]) do |c|
          if c[:type] == :content && !received_after_error
            received_after_error = true
            raise "ui broke"
          end
        end
      end.not_to raise_error
      expect(received_after_error).to be true
    end

    it "swallows flush-time errors too (#21)" do
      filter = Rubino::LLM::InlineThinkFilter.new
      allow(Rubino::LLM::InlineThinkFilter).to receive(:new).and_return(filter)
      allow(filter).to receive(:flush).and_raise("boom on flush")
      expect do
        adapter.stream(messages: [{ role: "user", content: "hi" }]) { |_| }
      end.not_to raise_error
    end
  end

  # -----------------------------------------------------------------------
  # Hidden render mode (#76): the adapter no longer drops :thinking deltas at
  # the emit gate — the CLI buffers them unrendered so Ctrl-O can reveal the
  # last thought even in hidden mode; UI::API drops them at its own boundary.
  # -----------------------------------------------------------------------
  describe "#stream thinking deltas in hidden mode (#76)" do
    it "still emits :thinking chunks so the CLI can retain them for ctrl-o" do
      cfg = test_configuration(
        "model" => { "provider" => "openai", "default" => "gpt-4o",
                     "temperature" => 0.3, "context_length" => nil },
        "display" => { "reasoning" => "hidden" }
      )
      chunk    = double("Chunk", content: nil, thinking: "private musing")
      response = double("Response", content: "", input_tokens: 1, output_tokens: 1, tool_calls: nil)
      c = double("Chat")
      allow(c).to receive(:with_instructions).and_return(c)
      allow(c).to receive(:messages).and_return([])
      allow(c).to receive(:ask) do |_, &blk|
        blk.call(chunk)
        response
      end
      adapter = described_class.new(model_id: "gpt-4o", config: cfg)
      allow(adapter).to receive(:build_chat).and_return(c)

      seen = []
      adapter.stream(messages: [{ role: "user", content: "hi" }]) { |ch| seen << ch }
      expect(seen.map { |ch| ch[:type] }).to include(:thinking)
      expect(seen.find { |ch| ch[:type] == :thinking }[:text]).to eq("private musing")
    end
  end

  # -----------------------------------------------------------------------
  # Graceful thinking degradation (#75): a provider on the anthropic-
  # compatible path that rejects the thinking budget must NOT hard-error the
  # turn — the adapter retries once without the budget, remembers the
  # rejection for the session, and tells the user once.
  # -----------------------------------------------------------------------
  describe "#call thinking-budget rejection (#75)" do
    let(:cfg) do
      # supports_thinking: true opts back into the budget (MiniMax-family ids
      # default to no-thinking, #2) so the rejection path has one to drop.
      test_configuration(
        "model" => { "provider" => "minimax", "default" => "MiniMax-M2.7",
                     "temperature" => 0.3, "context_length" => nil },
        "providers" => { "minimax" => {
          "anthropic_compatible" => true, "assume_model_exists" => true,
          "api_key" => "mm_secret", "base_url" => "https://api.minimax.io/anthropic",
          "supports_thinking" => true
        } }
      )
    end
    let(:ui)       { double("UI", note: nil) }
    let(:response) { double("Response", content: "hi there", input_tokens: 1, output_tokens: 1, tool_calls: nil) }
    let(:request)  { Rubino::LLM::Request.new(messages: [{ role: "user", content: "hi" }], stream: false) }

    after { Rubino::LLM::ThinkingSupport.reset! }

    # A chat double whose ask raises a thinking rejection the first
    # +rejections+ times, then succeeds.
    def rejecting_chat(rejections)
      c = double("Chat")
      allow(c).to receive(:with_instructions).and_return(c)
      allow(c).to receive(:messages).and_return([])
      calls = 0
      r = response
      allow(c).to receive(:ask) do
        calls += 1
        raise "invalid params: the thinking budget is not supported by this model" if calls <= rejections

        r
      end
      c
    end

    def adapter_with(chat)
      a = described_class.new(model_id: "MiniMax-M2.7", config: cfg, ui: ui)
      allow(a).to receive(:build_chat).and_return(chat)
      a
    end

    it "retries once without the budget and completes the turn" do
      chat = rejecting_chat(1)
      result = adapter_with(chat).call(request)
      expect(result.content).to eq("hi there")
      expect(chat).to have_received(:ask).twice
    end

    it "retries the streaming path too (the rejection is pre-first-chunk)" do
      chat = rejecting_chat(1)
      streaming = Rubino::LLM::Request.new(messages: [{ role: "user", content: "hi" }], stream: true)
      result = adapter_with(chat).call(streaming) { |_| }
      expect(result.content).to eq("hi there")
      expect(chat).to have_received(:ask).twice
    end

    it "remembers the rejection for the session (class-level memo)" do
      adapter_with(rejecting_chat(1)).call(request)
      expect(Rubino::LLM::ThinkingSupport.unsupported?("minimax")).to be(true)
      # Lifecycle rebuilds the adapter every turn — the NEXT instance must
      # already resolve a zero budget so the provider never sees one again.
      fresh = described_class.new(model_id: "MiniMax-M2.7", config: cfg, ui: ui)
      expect(fresh.send(:thinking_budget)).to eq(0)
    end

    it "tells the user once with a dim note" do
      adapter_with(rejecting_chat(1)).call(request)
      expect(ui).to have_received(:note)
        .with("provider doesn't support thinking — effort off").once
    end

    it "re-raises when the provider keeps rejecting after the budget was dropped (no retry loop)" do
      chat = rejecting_chat(2)
      expect { adapter_with(chat).call(request) }
        .to raise_error(/thinking budget is not supported/)
      expect(chat).to have_received(:ask).twice
    end

    it "re-raises unrelated errors untouched" do
      c = double("Chat")
      allow(c).to receive(:with_instructions).and_return(c)
      allow(c).to receive(:messages).and_return([])
      allow(c).to receive(:ask).and_raise("rate limited")
      expect { adapter_with(c).call(request) }.to raise_error("rate limited")
      expect(Rubino::LLM::ThinkingSupport.unsupported?("minimax")).to be(false)
      expect(ui).not_to have_received(:note)
    end

    it "ignores thinking-flavored errors on a non-anthropic path (no budget was sent)" do
      openai_cfg = test_configuration(
        "model" => { "provider" => "openai", "default" => "gpt-4o",
                     "temperature" => 0.3, "context_length" => nil }
      )
      c = double("Chat")
      allow(c).to receive(:with_instructions).and_return(c)
      allow(c).to receive(:messages).and_return([])
      allow(c).to receive(:ask).and_raise("thinking is not supported")
      a = described_class.new(model_id: "gpt-4o", config: openai_cfg, ui: ui)
      allow(a).to receive(:build_chat).and_return(c)
      expect { a.call(request) }.to raise_error(/thinking is not supported/)
      expect(Rubino::LLM::ThinkingSupport.unsupported?("openai")).to be(false)
    end
  end

  # -----------------------------------------------------------------------
  # Message block boundaries (prod session-50 fix)
  #
  # In a multi-step streamed turn the model narrates, calls a tool, then
  # narrates again. Without a block boundary the downstream UI splits one
  # message around the interleaved tool call (even mid-word). We tag every
  # content delta with the id of the assistant message it belongs to
  # (bumped on ruby_llm's before_message) and emit MESSAGE_COMPLETED at
  # after_message — the authoritative "this block is done" signal, mirroring
  # Anthropic content_block_stop / AI SDK text-end{id}.
  # -----------------------------------------------------------------------
  describe "#stream message block boundaries" do
    let(:event_bus) { Rubino::Interaction::EventBus.new }

    # Fake chat reproducing two assistant messages separated by a tool step:
    #   block 1: "Cerco le notizie in par"   (tool runs here)
    #   block 2: "allelo. Pronto."
    let(:chunk1)   { double("Chunk", content: "Cerco le notizie in par", thinking: nil) }
    let(:chunk2)   { double("Chunk", content: "allelo. Pronto.", thinking: nil) }
    let(:response) do
      double("Response", content: "Cerco le notizie in parallelo. Pronto.", input_tokens: 1, output_tokens: 1,
                         tool_calls: nil)
    end
    let(:fake_chat) do
      c = Object.new
      callbacks = {}
      ch1 = chunk1
      ch2 = chunk2
      resp = response
      c.define_singleton_method(:with_tool) { |*| c }
      c.define_singleton_method(:with_instructions) { |*| c }
      c.define_singleton_method(:messages) { [] }
      c.define_singleton_method(:before_message) { |&blk| callbacks[:new] = blk }
      c.define_singleton_method(:after_message) { |&blk| callbacks[:end] = blk }
      c.define_singleton_method(:ask) do |_, **_kw, &blk|
        callbacks[:new].call
        blk.call(ch1)
        callbacks[:end].call # block 1 done — a tool would execute here
        callbacks[:new].call
        blk.call(ch2)
        callbacks[:end].call # block 2 done
        resp
      end
      c
    end

    let(:adapter) do
      cfg = test_configuration(
        "model" => { "provider" => "openai", "default" => "gpt-4o", "temperature" => 0.3, "context_length" => nil }
      )
      a = described_class.new(model_id: "gpt-4o", config: cfg, event_bus: event_bus)
      allow(a).to receive(:build_chat).and_return(fake_chat)
      a
    end

    it "tags content deltas with a per-message id and closes each block with MESSAGE_COMPLETED" do
      completed = []
      event_bus.on(Rubino::Interaction::Events::MESSAGE_COMPLETED) { |p| completed << p[:message_id] }

      text_by_id = Hash.new { |h, k| h[k] = +"" }
      adapter.stream(messages: [{ role: "user", content: "hi" }]) do |chunk|
        text_by_id[chunk[:message_id]] << chunk[:text] if chunk[:type] == :content
      end

      # Two distinct assistant messages, each with its own id — never merged,
      # never split. The tool step between them does not break a block.
      expect(text_by_id.keys).to eq([1, 2])
      expect(text_by_id[1]).to include("in par")
      expect(text_by_id[2]).to include("allelo")
      # One boundary per block, in order.
      expect(completed).to eq([1, 2])
    end

    # #261: ruby_llm runs tools mid-stream and returns a response whose #content
    # is only the LAST assistant block. The pre-tool narration (block 1) must
    # still survive into the AdapterResponse content (and thus the headless
    # output + persisted transcript) — built from the full streamed buffer, not
    # response.content alone.
    context "when the provider returns only the final block as #content (post-tool turn)" do
      let(:response) do
        double("Response", content: "allelo. Pronto.", input_tokens: 1, output_tokens: 1, tool_calls: nil)
      end

      it "returns the full turn text (pre-tool narration included), not just the last block" do
        result = adapter.stream(messages: [{ role: "user", content: "hi" }]) { |_| }
        expect(result.content).to eq("Cerco le notizie in parallelo. Pronto.")
      end
    end
  end

  # NOTE: (Slice 4): the adapter's retry helpers (with_retries, backoff_cap,
  # backoff_cap_for, cancellable_sleep, auth_error?/raise_with_auth_hint) moved
  # to Agent::ModelCallRunner — the single retry owner — to avoid double-retry.
  # Their behaviour is now covered by model_call_runner_spec.rb. The adapter only
  # RAISES retryable errors (and pre-first-chunk stream drops) for the runner to
  # retry; the streaming raise-vs-return-partial decision stays here (see below).

  # ruby_llm 1.15 installs its OWN faraday-retry (default max=3) on the
  # streaming POST connection, which re-invokes the on_data handler on a drop
  # -> double output + a retry storm multiplying with the runner's retries. The
  # runner owns retry, so the gem's must be off.
  describe "gem-level retry is disabled" do
    it "sets RubyLLM.config.max_retries = 0" do
      cfg = test_configuration("model" => { "provider" => "openai", "default" => "gpt-4o" })
      described_class.new(model_id: "gpt-4o", config: cfg)
      expect(RubyLLM.config.max_retries).to eq(0)
    end

    it "defaults request_timeout to 600s (per-read idle bound, SDK-standard)" do
      cfg = test_configuration("model" => { "provider" => "openai", "default" => "gpt-4o" })
      described_class.new(model_id: "gpt-4o", config: cfg)
      expect(RubyLLM.config.request_timeout).to eq(600)
    end

    it "honors providers.<name>.request_timeout_seconds override" do
      cfg = test_configuration(
        "model" => { "provider" => "openai", "default" => "gpt-4o" },
        "providers" => { "openai" => { "request_timeout_seconds" => 1200 } }
      )
      described_class.new(model_id: "gpt-4o", config: cfg)
      expect(RubyLLM.config.request_timeout).to eq(1200)
    end
  end

  # The core streaming-safety decision (still in the adapter after Slice 4): a
  # pre-first-chunk transport drop is RAISED (the runner re-issues a fresh
  # request — safe, no token reached the user); a post-first-chunk drop preserves
  # the buffered partial and RETURNS it interrupted (never retried — no double
  # output). The adapter itself no longer loops on retries; that is the runner's
  # job (see model_call_runner_spec.rb).
  describe "#stream transport-drop raise-vs-partial decision" do
    let(:response) { double("Response", content: "ignored", input_tokens: 1, output_tokens: 1, tool_calls: nil) }

    def adapter_for(chat)
      cfg = test_configuration(
        "model" => { "provider" => "openai", "default" => "gpt-4o", "temperature" => 0.3, "context_length" => nil }
      )
      a = described_class.new(model_id: "gpt-4o", config: cfg)
      allow(a).to receive(:build_chat).and_return(chat)
      a
    end

    it "RAISES the drop when it happens before any chunk (nothing shown — runner can re-issue)" do
      chat = double("Chat", with_tool: nil, with_instructions: nil, messages: [])
      allow(chat).to receive(:ask).and_raise(Faraday::ConnectionFailed, "end of file reached")

      adapter = adapter_for(chat)

      expect do
        adapter.stream(messages: [{ role: "user", content: "hi" }]) { |_| }
      end.to raise_error(Faraday::ConnectionFailed)
      expect(chat).to have_received(:ask).once # adapter does NOT retry itself anymore
    end

    it "does NOT raise after a chunk flowed — preserves partial, emits each chunk once" do
      calls = 0
      chat = double("Chat", with_tool: nil, with_instructions: nil, messages: [])
      allow(chat).to receive(:ask) do |_, &blk|
        calls += 1
        blk.call(double("Chunk", content: "Hello ", thinking: nil))
        blk.call(double("Chunk", content: "world",  thinking: nil))
        raise Faraday::ConnectionFailed, "end of file reached"
      end

      adapter = adapter_for(chat)
      emitted = []
      out = adapter.stream(messages: [{ role: "user", content: "hi" }]) do |c|
        emitted << c[:text] if c[:type] == :content
      end

      expect(calls).to eq(1)                    # NOT retried after output
      expect(emitted.join).to eq("Hello world") # content delivered once, not duplicated
      expect(out.content).to eq("Hello world")  # buffered partial preserved
      expect(out.interrupted?).to be true # flagged so the Loop fails the turn, not "completed"
    end
  end

  # Regression: when a session is resumed, PromptAssembler reads the tool
  # messages back from the DB with their tool_call_id intact, but
  # load_history dropped it on the floor. Anthropic and Bedrock validate
  # that every tool message's id matches a preceding assistant toolUse and
  # 400 otherwise — the resumed conversation hit the wire malformed.
  describe "#load_history (private)" do
    let(:cfg) { test_configuration("model" => { "provider" => "openai", "default" => "gpt-4o" }) }
    let(:adapter) { described_class.new(model_id: "gpt-4o", config: cfg) }
    let(:chat)    { instance_double(RubyLLM::Chat, messages: [], with_instructions: nil) }

    it "preserves tool_call_id on tool messages" do
      messages = [
        { role: "user",      content: "list files" },
        { role: "assistant", content: "ok" },
        { role: "tool",      content: "a.rb\nb.rb", tool_call_id: "call_42" },
        { role: "user",      content: "thanks" }
      ]

      adapter.send(:load_history, chat, messages)
      tool_msg = chat.messages.find { |m| m.role == :tool }
      expect(tool_msg).not_to be_nil
      expect(tool_msg.tool_call_id).to eq("call_42")
    end

    it "accepts both symbol and string tool_call_id keys" do
      messages = [
        { role: "tool", content: "x", "tool_call_id" => "string_key" },
        { role: "user", content: "next" }
      ]

      adapter.send(:load_history, chat, messages)
      expect(chat.messages.first.tool_call_id).to eq("string_key")
    end

    # Regression: even with tool_call_id preserved on tool messages (#110),
    # strict providers still 400 because the ASSISTANT turn that originated
    # the toolUse was persisted without its tool_calls array. Loop now
    # stashes them under metadata; load_history reconstructs RubyLLM::ToolCall
    # objects so the assistant block contains the toolUse block on resume.
    it "rebuilds tool_calls on assistant messages so the toolUse block is intact" do
      messages = [
        { role: "user", content: "list files" },
        {
          role: "assistant",
          content: "let me check",
          tool_calls: [{ id: "call_1", name: "shell", arguments: { command: "ls" } }]
        },
        { role: "tool", content: "a.rb\nb.rb", tool_call_id: "call_1" },
        { role: "user", content: "thanks" }
      ]

      adapter.send(:load_history, chat, messages)
      assistant = chat.messages.find { |m| m.role == :assistant }
      expect(assistant.tool_calls).to be_an(Array)
      expect(assistant.tool_calls.first).to be_a(RubyLLM::ToolCall)
      expect(assistant.tool_calls.first.id).to eq("call_1")
      expect(assistant.tool_calls.first.name).to eq("shell")
    end

    it "treats nil/empty tool_calls as a plain assistant turn" do
      messages = [
        { role: "assistant", content: "no tools here", tool_calls: [] },
        { role: "user", content: "next" }
      ]

      adapter.send(:load_history, chat, messages)
      assistant = chat.messages.find { |m| m.role == :assistant }
      expect(assistant.tool_calls).to be_nil
    end
  end

  # Prefill-to-continue (Slice 5, rung 4): request.prefill must reach the wire as
  # a TRAILING assistant message so a thinking-only model continues from it.
  describe "#apply_prefill (private)" do
    let(:cfg)     { test_configuration("model" => { "provider" => "openai", "default" => "gpt-4o" }) }
    let(:adapter) { described_class.new(model_id: "gpt-4o", config: cfg) }
    let(:chat)    { instance_double(RubyLLM::Chat, messages: []) }

    it "appends the prefill seed as a trailing assistant message" do
      adapter.send(:apply_prefill, chat, "Let me continue from my reasoning: ")
      expect(chat.messages.size).to eq(1)
      seed = chat.messages.last
      expect(seed.role).to eq(:assistant)
      expect(seed.content).to eq("Let me continue from my reasoning: ")
    end

    it "is a no-op for a nil or blank seed (no degenerate empty turn on the wire)" do
      adapter.send(:apply_prefill, chat, nil)
      adapter.send(:apply_prefill, chat, "   ")
      expect(chat.messages).to be_empty
    end
  end
end
