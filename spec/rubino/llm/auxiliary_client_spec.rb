# frozen_string_literal: true

RSpec.describe Rubino::LLM::AuxiliaryClient do
  # test_configuration#to_hash does a shallow dup, so direct `set` on nested
  # keys would mutate MODULE_DEFAULTS and pollute other specs. Build a deep
  # clone of the defaults and overlay the test-specific values up front.
  let(:raw) do
    base = Marshal.load(Marshal.dump(Rubino::Config::Defaults.to_hash))
    base["model"]["default"]  = "fake/happy-path"
    base["model"]["provider"] = "fake"
    base["database"] = { "path" => ":memory:" }
    base["paths"]    = { "home" => TEST_HOME, "memory" => "#{TEST_HOME}/memories", "logs" => "#{TEST_HOME}/logs" }
    base
  end
  let(:config) { Rubino::Config::Configuration.new(raw: raw, home_path: TEST_HOME) }
  subject(:client) { described_class.new(config: config) }

  describe "#call" do
    it "raises ArgumentError when the task has no aux block" do
      expect {
        client.call(task: :nonexistent, messages: [{ role: "user", content: "hi" }])
      }.to raise_error(ArgumentError, /nonexistent/)
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
      config.set("auxiliary", "vision", { "provider" => "openai", "model" => "gpt-4o-mini", "base_url" => nil, "timeout" => 60 })

      adapter = instance_double(Rubino::LLM::FakeProvider, chat: build_response("ok"))
      expect(Rubino::LLM::AdapterFactory).to receive(:build).with(
        hash_including(model_id: "gpt-4o-mini", provider: "openai")
      ).and_return(adapter)

      client.call(task: :vision, messages: [])
    end

    it "treats provider: 'main' as the primary's provider" do
      config.set("auxiliary", "vision", { "provider" => "main", "model" => "vision-x", "base_url" => nil, "timeout" => 60 })

      adapter = instance_double(Rubino::LLM::FakeProvider, chat: build_response("ok"))
      expect(Rubino::LLM::AdapterFactory).to receive(:build).with(
        hash_including(model_id: "vision-x", provider: "fake")
      ).and_return(adapter)

      client.call(task: :vision, messages: [])
    end

    it "passes a transient base_url overlay through provider_config" do
      config.set("auxiliary", "vision", { "provider" => "openai", "model" => "vx", "base_url" => "http://aux.local/v1", "timeout" => 60 })

      adapter = instance_double(Rubino::LLM::FakeProvider, chat: build_response("ok"))
      expect(Rubino::LLM::AdapterFactory).to receive(:build) do |kwargs|
        overlay = kwargs[:config]
        expect(overlay.provider_config("openai")["base_url"]).to eq("http://aux.local/v1")
        adapter
      end

      client.call(task: :vision, messages: [])
    end
  end

  def build_response(text)
    Rubino::LLM::AdapterResponse.new(
      content: text, tool_calls: [], input_tokens: 0, output_tokens: 0, model_id: "fake"
    )
  end
end
