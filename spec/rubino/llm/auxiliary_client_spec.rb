# frozen_string_literal: true

RSpec.describe Rubino::LLM::AuxiliaryClient do
  # test_configuration#to_hash does a shallow dup, so direct `set` on nested
  # keys would mutate MODULE_DEFAULTS and pollute other specs. Build a deep
  # clone of the defaults and overlay the test-specific values up front.
  subject(:client) { described_class.new(config: config) }

  let(:raw) do
    base = Marshal.load(Marshal.dump(Rubino::Config::Defaults.to_hash))
    base["model"]["default"]  = "fake/happy-path"
    base["model"]["provider"] = "fake"
    base["database"] = { "path" => ":memory:" }
    base["paths"]    = { "home" => TEST_HOME, "memory" => "#{TEST_HOME}/memories", "logs" => "#{TEST_HOME}/logs" }
    base
  end
  let(:config) { Rubino::Config::Configuration.new(raw: raw, home_path: TEST_HOME) }

  describe "#call" do
    it "raises ArgumentError when the task has no aux block" do
      expect do
        client.call(task: :nonexistent, messages: [{ role: "user", content: "hi" }])
      end.to raise_error(ArgumentError, /nonexistent/)
    end

    it "falls back to the primary model when aux.model is empty" do
      config.set("auxiliary", "vision", { "provider" => "main", "model" => "", "base_url" => nil, "timeout" => 120 })

      adapter = instance_double(Rubino::LLM::FakeProvider, chat: build_response("ok"))
      expect(Rubino::LLM::AdapterFactory).to receive(:build).with(
        hash_including(model_id: "fake/happy-path", provider: "fake")
      ).and_return(adapter)

      client.call(task: :vision, messages: [{ role: "user", content: "x" }])
    end

    it "uses the aux model when set and resolves provider via the override" do
      config.set("auxiliary", "vision",
                 { "provider" => "openai", "model" => "gpt-4o-mini", "base_url" => nil, "timeout" => 60 })

      adapter = instance_double(Rubino::LLM::FakeProvider, chat: build_response("ok"))
      expect(Rubino::LLM::AdapterFactory).to receive(:build).with(
        hash_including(model_id: "gpt-4o-mini", provider: "openai")
      ).and_return(adapter)

      client.call(task: :vision, messages: [])
    end

    it "treats provider: 'main' as the primary's provider" do
      config.set("auxiliary", "vision",
                 { "provider" => "main", "model" => "vision-x", "base_url" => nil, "timeout" => 60 })

      adapter = instance_double(Rubino::LLM::FakeProvider, chat: build_response("ok"))
      expect(Rubino::LLM::AdapterFactory).to receive(:build).with(
        hash_including(model_id: "vision-x", provider: "fake")
      ).and_return(adapter)

      client.call(task: :vision, messages: [])
    end

    it "passes a transient base_url overlay through provider_config" do
      config.set("auxiliary", "vision",
                 { "provider" => "openai", "model" => "vx", "base_url" => "http://aux.local/v1", "timeout" => 60 })

      adapter = instance_double(Rubino::LLM::FakeProvider, chat: build_response("ok"))
      expect(Rubino::LLM::AdapterFactory).to receive(:build) do |kwargs|
        overlay = kwargs[:config]
        expect(overlay.provider_config("openai")["base_url"]).to eq("http://aux.local/v1")
        adapter
      end

      client.call(task: :vision, messages: [])
    end
  end

  # The aux prompt PREFIX (the system message) is byte-stable across same-task
  # calls — the task instructions never change — while the user transcript grows.
  # When prompt caching is on we stamp a cache_control breakpoint on that stable
  # head so the model server caches the shared prefix instead of paying full
  # uncached input every turn (memory/skill/summary all fire ~every turn). When
  # caching is off the messages must be byte-identical to before (plain strings).
  describe "#call prompt-cache breakpoint" do
    let(:adapter) { instance_double(Rubino::LLM::FakeProvider) }

    before do
      config.set("auxiliary", "summarize",
                 { "provider" => "main", "model" => "", "base_url" => nil, "timeout" => 300 })
      allow(Rubino::LLM::AdapterFactory).to receive(:build).and_return(adapter)
    end

    def capture_messages
      captured = nil
      allow(adapter).to receive(:chat) do |**kw|
        captured = kw[:messages]
        build_response("ok")
      end
      client.call(task: :summarize,
                  messages: [{ role: "system", content: "STABLE SYSTEM PROMPT" },
                             { role: "user", content: "the transcript" }])
      captured
    end

    context "when prompts.prompt_cache is on (default)" do
      it "wraps the system content in a Content::Raw block carrying a cache_control marker" do
        config.set("prompts", "prompt_cache", true)
        msgs = capture_messages

        sys = msgs.find { |m| m[:role] == "system" }
        expect(sys[:content]).to be_a(RubyLLM::Content::Raw)
        block = sys[:content].value.first
        expect(block["text"]).to eq("STABLE SYSTEM PROMPT")
        expect(block["cache_control"]).to eq("type" => "ephemeral")
      end

      it "leaves the (growing) user message a plain string AFTER the cached head" do
        config.set("prompts", "prompt_cache", true)
        msgs = capture_messages

        user = msgs.find { |m| m[:role] == "user" }
        expect(user[:content]).to eq("the transcript")
      end

      it "is deterministic — two calls produce a byte-identical cached block" do
        config.set("prompts", "prompt_cache", true)
        first  = capture_messages.find { |m| m[:role] == "system" }[:content].value
        second = capture_messages.find { |m| m[:role] == "system" }[:content].value
        expect(first).to eq(second)
      end
    end

    context "when prompts.prompt_cache is off" do
      it "leaves the messages as plain strings, unchanged" do
        config.set("prompts", "prompt_cache", false)
        msgs = capture_messages

        sys = msgs.find { |m| m[:role] == "system" }
        expect(sys[:content]).to eq("STABLE SYSTEM PROMPT")
        expect(sys[:content]).to be_a(String)
      end
    end
  end

  def build_response(text)
    Rubino::LLM::AdapterResponse.new(
      content: text, tool_calls: [], input_tokens: 0, output_tokens: 0, model_id: "fake"
    )
  end
end
