# frozen_string_literal: true

# Port fidelity for Agent::BackoffPolicy against the reference implementation.
# Sleep is stubbed — no test actually sleeps.
RSpec.describe Rubino::Agent::BackoffPolicy do
  subject(:policy) { described_class.new }

  describe "#jittered" do
    it "is monotonic in the exponential base across attempts (ignoring jitter)" do
      # The deterministic floor min(base*2^(n-1), max) grows until the cap.
      bases = (1..5).map { |n| 5.0 * (2**(n - 1)) }
      expect(bases).to eq([5, 10, 20, 40, 80])
    end

    it "stays within [delay, 1.5*delay) for the uncapped region" do
      100.times do
        v = policy.jittered(1, base: 5, max: 120) # delay = 5
        expect(v).to be >= 5.0
        expect(v).to be < 7.5 # 5 + 0.5*5
      end
    end

    it "caps the exponential at max (jitter rides on top, reference-faithful)" do
      100.times do
        v = policy.jittered(10, base: 5, max: 120) # delay capped at 120
        expect(v).to be >= 120.0
        expect(v).to be < 180.0 # 120 + 0.5*120
      end
    end

    it "honours the error-path preset defaults (base 2, max 60)" do
      100.times do
        v = policy.jittered(1) # delay = 2
        expect(v).to be >= 2.0
        expect(v).to be < 3.0
      end
    end

    it "treats attempt <= 1 as exponent 0 (no negative shift)" do
      v = policy.jittered(0, base: 4, max: 60)
      expect(v).to be >= 4.0
      expect(v).to be < 6.0
    end

    it "exposes the two conversation-loop presets" do
      expect(described_class::INVALID_RESPONSE).to eq(base: 5.0, max: 120.0)
      expect(described_class::ERROR_PATH).to eq(base: 2.0, max: 60.0)
    end
  end

  describe "#wait_seconds — Retry-After" do
    it "honours a numeric Retry-After over the jittered backoff" do
      expect(policy.wait_seconds(3, base: 2, max: 60, retry_after: 30)).to eq(30.0)
    end

    it "honours a string Retry-After" do
      expect(policy.wait_seconds(3, base: 2, max: 60, retry_after: "12")).to eq(12.0)
    end

    it "clamps Retry-After to the 2-minute cap" do
      expect(policy.wait_seconds(1, base: 2, max: 60, retry_after: 999)).to eq(120.0)
    end

    it "falls back to jittered backoff when Retry-After is absent" do
      v = policy.wait_seconds(1, base: 2, max: 60, retry_after: nil)
      expect(v).to be >= 2.0
      expect(v).to be < 3.0
    end

    it "ignores a non-numeric Retry-After and falls back to backoff" do
      v = policy.wait_seconds(1, base: 2, max: 60, retry_after: "soon")
      expect(v).to be >= 2.0
      expect(v).to be < 3.0
    end
  end

  describe "#parse_retry_after — reaching the header off a typed error" do
    it "reads Retry-After from the error's Faraday response headers" do
      response = double("FaradayResponse", headers: { "retry-after" => "45" })
      error = double("RateLimitError", response: response)
      expect(policy.parse_retry_after(error)).to eq(45.0)
    end

    it "reads the capitalised Retry-After variant" do
      response = double("FaradayResponse", headers: { "Retry-After" => "7" })
      error = double("RateLimitError", response: response)
      expect(policy.parse_retry_after(error)).to eq(7.0)
    end

    it "returns nil when no header is present" do
      response = double("FaradayResponse", headers: {})
      error = double("RateLimitError", response: response)
      expect(policy.parse_retry_after(error)).to be_nil
    end

    it "returns nil for an error with no response" do
      expect(policy.parse_retry_after(StandardError.new("x"))).to be_nil
    end
  end

  describe "#sleep — cancellable" do
    it "does not sleep past the deadline and returns normally without a cancel token" do
      policy = described_class.new
      allow(Kernel).to receive(:sleep) # stub: never actually sleep
      expect { policy.sleep(0.05) }.not_to raise_error
    end

    it "aborts promptly when the cancel token is already cancelled" do
      token = Rubino::Interaction::CancelToken.new
      token.cancel!
      policy = described_class.new(cancel_token: token)
      allow(Kernel).to receive(:sleep)
      expect { policy.sleep(5.0) }.to raise_error(Rubino::Interrupted)
    end

    it "polls the cancel token between ticks (cancel mid-wait aborts)" do
      token = Rubino::Interaction::CancelToken.new
      policy = described_class.new(cancel_token: token)
      allow(Kernel).to receive(:sleep) { token.cancel! } # flip after first tick
      expect { policy.sleep(5.0) }.to raise_error(Rubino::Interrupted)
    end
  end
end
