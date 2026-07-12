# frozen_string_literal: true

# Stale-stream watchdog deadline policy, ported from Hermes'
# _compute_non_stream_stale_timeout: explicit config wins; LOCAL endpoints
# auto-disable the watchdog (a large local model can prefill for minutes before
# the first token — the "no chunk received for 30s" abort that killed local
# models); remote default is 90s, scaled up for large contexts.
RSpec.describe Rubino::LLM::RubyLLMAdapter do
  def adapter_for(provider:, base_url: nil, stale: nil)
    prov = { "openai_compatible" => true, "assume_model_exists" => true, "api_key" => "fake" }
    prov["base_url"] = base_url if base_url
    prov["stale_timeout_seconds"] = stale unless stale.nil?
    config = test_configuration(
      "model" => { "provider" => provider, "default" => "test-model" },
      "providers" => { provider => prov }
    )
    described_class.new(model_id: "test-model", config: config)
  end

  def stale(adapter, messages = nil) = adapter.send(:stale_chunk_timeout, messages)

  describe "#local_endpoint?" do
    {
      "http://127.0.0.1:8000/v1" => true,
      "http://localhost:1234/v1" => true,
      "http://host.docker.internal:8000/v1" => true,
      "http://192.168.1.50:11434/v1" => true,
      "http://10.0.0.7:8000/v1" => true,
      "http://172.16.4.2:8000/v1" => true,
      "http://100.96.0.3:8000/v1" => true, # Tailscale CGNAT
      "https://api.openai.com/v1" => false,
      "https://api.deepseek.com/v1" => false,
      "https://8.8.8.8/v1" => false
    }.each do |url, expected|
      it "is #{expected} for #{url}" do
        expect(adapter_for(provider: "gw", base_url: url).send(:local_endpoint?)).to be(expected)
      end
    end

    it "is false when no base_url is configured" do
      a = adapter_for(provider: "gw", base_url: "http://127.0.0.1:8000/v1")
      allow(a).to receive(:provider_cfg).and_return({})
      expect(a.send(:local_endpoint?)).to be(false)
    end
  end

  describe "#stale_chunk_timeout" do
    it "DISABLES the watchdog (0) for a local endpoint with no explicit config" do
      a = adapter_for(provider: "gw", base_url: "http://host.docker.internal:8000/v1")
      expect(stale(a)).to eq(0) # the local-model prefill fix
    end

    it "honours an explicit stale_timeout_seconds even on a local endpoint" do
      a = adapter_for(provider: "gw", base_url: "http://127.0.0.1:8000/v1", stale: 600)
      expect(stale(a)).to eq(600)
    end

    it "defaults a remote provider to 90s" do
      a = adapter_for(provider: "gw", base_url: "https://api.example.com/v1")
      expect(stale(a)).to eq(90)
    end

    it "scales the remote deadline up for large contexts" do
      a = adapter_for(provider: "gw", base_url: "https://api.example.com/v1")
      big = [{ role: "user", content: "x" * (60_000 * 4) }]    # ~60k tokens
      huge = [{ role: "user", content: "x" * (120_000 * 4) }]  # ~120k tokens
      expect(stale(a, big)).to eq(150)
      expect(stale(a, huge)).to eq(240)
    end
  end
end
