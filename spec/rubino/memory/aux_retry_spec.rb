# frozen_string_literal: true

# Cancellation of the aux retry/backoff loop (#319). The post-turn polishing
# runs DETACHED and must abort the moment the user presses Esc — including
# mid-backoff under a 429 storm, which is the ~80s stall the issue reports.
RSpec.describe Rubino::Memory::AuxRetry do
  # Minimal host: the mixin reads extract_max_retries from @config (we set it
  # below), so the DEFAULT_EXTRACT_MAX_RETRIES fallback constant is never hit.
  let(:host_class) do
    Class.new do
      include Rubino::Memory::AuxRetry

      def initialize(config) = (@config = config)
      def public_with_aux_retry(&) = with_aux_retry(&)
    end
  end
  let(:config) { test_configuration("memory" => { "extract_max_retries" => 3 }) }
  let(:host)   { host_class.new(config) }
  let(:token)  { Rubino::Interaction::CancelToken.new }

  # A retryable 429 so the loop would normally back off and retry.
  let(:rate_limited) do
    Class.new(StandardError) do
      def http_status = 429
    end.new("429 rate limited")
  end

  let(:classified) do
    Rubino::LLM::ClassifiedError.new(
      reason: Rubino::LLM::FailoverReason::RATE_LIMIT, status_code: 429,
      message: "429", retryable: true, should_compress: false,
      should_rotate_credential: false, should_fallback: false
    )
  end

  before do
    allow(Rubino::LLM::ErrorClassifier).to receive(:classify).and_return(classified)
  end

  context "when no aux cancel token is bound (foreground / API path)" do
    before do
      # Stub the host's backoff so the retries don't actually sleep.
      backoff = instance_double(Rubino::Agent::BackoffPolicy, sleep: nil, wait_seconds: 0,
                                                              parse_retry_after: nil)
      allow(host).to receive(:aux_backoff).and_return(backoff)
    end

    it "retries as before and never polls a cancel token" do
      calls = 0
      expect do
        host.public_with_aux_retry do
          calls += 1
          raise rate_limited
        end
      end.to raise_error(StandardError)
      # 1 initial + 3 retries (the configured budget).
      expect(calls).to eq(4)
    end
  end

  context "when a cancel token is bound (detached polishing) and already cancelled" do
    it "aborts BEFORE the first aux call instead of running it" do
      token.cancel!
      called = false
      Rubino.with_aux_cancel_token(token) do
        expect do
          host.public_with_aux_retry { called = true }
        end.to raise_error(Rubino::Interrupted)
      end
      expect(called).to be(false)
    end
  end

  context "when cancelled DURING the backoff wait (the 80s 429 stall)" do
    it "aborts the wait promptly rather than sleeping the full window" do
      # Flip the token from another thread shortly after the backoff sleep begins.
      Thread.new do
        sleep(0.05)
        token.cancel!
      end

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      Rubino.with_aux_cancel_token(token) do
        expect do
          host.public_with_aux_retry { raise rate_limited }
        end.to raise_error(Rubino::Interrupted)
      end
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

      # The cancellable sleep slices at ~0.1s, so the abort lands far below the
      # multi-second (Retry-After-honouring) backoff window.
      expect(elapsed).to be < 1.0
    end
  end
end
