# frozen_string_literal: true

require "ruby_llm"

# Port fidelity for LLM::ErrorClassifier against the reference implementation.
# The load-bearing default is unknown -> retryable.
RSpec.describe Rubino::LLM::ErrorClassifier do
  FR = Rubino::LLM::FailoverReason

  # Build a typed RubyLLM error the way ErrorMiddleware does:
  # RubyLLM::Error.new(response, message), where response carries the status.
  def ruby_llm_error(klass, status, message, headers: {})
    response = double("FaradayResponse", status: status, body: message, headers: headers)
    klass.new(response, message)
  end

  describe ".classify — typed ruby_llm errors" do
    # reason, retryable, [class, status, message]
    cases = {
      RubyLLM::RateLimitError => [FR::RATE_LIMIT, true, 429],
      RubyLLM::ServerError => [FR::SERVER_ERROR, true, 500],
      RubyLLM::ServiceUnavailableError => [FR::OVERLOADED, true, 503],
      RubyLLM::OverloadedError => [FR::OVERLOADED, true, 529],
      RubyLLM::UnauthorizedError => [FR::AUTH, false, 401],
      RubyLLM::ForbiddenError => [FR::AUTH, false, 403],
      RubyLLM::PaymentRequiredError => [FR::BILLING, false, 402]
    }

    cases.each do |klass, (reason, retryable, status)|
      it "maps #{klass} -> #{reason} (retryable=#{retryable})" do
        c = described_class.classify(ruby_llm_error(klass, status, "boom"))
        expect(c.reason).to eq(reason)
        expect(c.retryable).to eq(retryable)
      end
    end

    it "ContextLengthExceededError -> context_overflow, not retryable, should_compress" do
      c = described_class.classify(ruby_llm_error(RubyLLM::ContextLengthExceededError, 429, "context length exceeded"))
      expect(c.reason).to eq(FR::CONTEXT_OVERFLOW)
      expect(c.retryable).to be false
      expect(c.should_compress).to be true
    end

    it "auth errors carry the rotate-credential + fallback hints" do
      c = described_class.classify(ruby_llm_error(RubyLLM::UnauthorizedError, 401, "no"))
      expect(c.should_rotate_credential).to be true
      expect(c.should_fallback).to be true
      expect(c.auth?).to be true
    end
  end

  describe ".classify — by HTTP status" do
    it "401 -> auth, not retryable" do
      expect(described_class.classify(ruby_llm_error(RubyLLM::Error, 401, "x")).retryable).to be false
    end

    it "400 bad request -> format_error, not retryable" do
      c = described_class.classify(ruby_llm_error(RubyLLM::Error, 400, "Invalid request near token 502"))
      expect(c.reason).to eq(FR::FORMAT_ERROR)
      expect(c.retryable).to be false
    end

    it "400 with a model-not-found phrase -> model_not_found, not retryable" do
      c = described_class.classify(ruby_llm_error(RubyLLM::Error, 400, "invalid model 'foo'"))
      expect(c.reason).to eq(FR::MODEL_NOT_FOUND)
      expect(c.retryable).to be false
    end

    it "400 with a context-overflow phrase -> context_overflow, should_compress" do
      c = described_class.classify(ruby_llm_error(RubyLLM::Error, 400, "prompt is too long for context window"))
      expect(c.reason).to eq(FR::CONTEXT_OVERFLOW)
      expect(c.should_compress).to be true
    end

    it "404 with model-not-found -> model_not_found" do
      c = described_class.classify(ruby_llm_error(RubyLLM::Error, 404, "model not found"))
      expect(c.reason).to eq(FR::MODEL_NOT_FOUND)
    end

    it "generic 404 (no signal) -> unknown, retryable" do
      c = described_class.classify(ruby_llm_error(RubyLLM::Error, 404, "not found"))
      expect(c.reason).to eq(FR::UNKNOWN)
      expect(c.retryable).to be true
    end

    it "any 5xx status -> retryable server_error" do
      expect(described_class.classify(ruby_llm_error(RubyLLM::Error, 599, "weird")).retryable).to be true
    end

    it "503/529 -> overloaded, retryable" do
      [503, 529].each do |s|
        c = described_class.classify(ruby_llm_error(RubyLLM::Error, s, "busy"))
        expect(c.reason).to eq(FR::OVERLOADED)
        expect(c.retryable).to be true
      end
    end
  end

  describe ".classify — transport drops (no status)" do
    [
      Faraday::ConnectionFailed.new("end of file reached"),
      Faraday::TimeoutError.new("request timed out"),
      Net::ReadTimeout.new,
      Net::OpenTimeout.new("connect timed out"),
      EOFError.new("end of file reached"),
      Errno::ECONNRESET.new
    ].each do |err|
      it "#{err.class} -> timeout, retryable" do
        c = described_class.classify(err)
        expect(c.reason).to eq(FR::TIMEOUT)
        expect(c.retryable).to be true
      end
    end

    it "an untyped transport-drop message is retryable (no-status fallback)" do
      expect(described_class.retryable?(StandardError.new("request timed out after 60s"))).to be true
      expect(described_class.retryable?(StandardError.new("connection reset by peer"))).to be true
    end
  end

  describe ".classify — MiniMax unknown-provider blip (folds Slice 0b)" do
    it "no-status 'unknown error' -> unknown, retryable" do
      c = described_class.classify(RubyLLM::Error.new(nil, "unknown error"))
      expect(c.reason).to eq(FR::UNKNOWN)
      expect(c.retryable).to be true
    end

    it "no-status api_error code 999 -> retryable" do
      err = RubyLLM::Error.new(nil, 'API request failed: {"error":{"code":999,"message":"unknown error"}}')
      expect(described_class.retryable?(err)).to be true
    end

    it "no-status code 1000 -> retryable" do
      expect(described_class.retryable?(RubyLLM::Error.new(nil, "provider returned code 1000"))).to be true
    end

    it "529 'unknown error' -> retryable (overloaded)" do
      expect(described_class.retryable?(ruby_llm_error(RubyLLM::Error, 529, "unknown error from upstream"))).to be true
    end

    it "401 that mentions 'unknown error' stays permanent (status wins)" do
      expect(described_class.retryable?(ruby_llm_error(RubyLLM::Error, 401, "unknown error"))).to be false
    end

    it "400 that mentions 'unknown error' stays permanent" do
      expect(described_class.retryable?(ruby_llm_error(RubyLLM::Error, 400, "unknown error in request"))).to be false
    end
  end

  # #93: a missing/unconfigured credential is raised BEFORE any HTTP call, so
  # it has no status and used to fall through to unknown->retryable, triggering
  # an ~80s retry storm that exited empty. It must be NON-retryable AUTH so the
  # runner surfaces it immediately.
  describe ".classify — missing credential fails fast (#93)" do
    it "RubyLLM::ConfigurationError (missing key) -> auth, NOT retryable" do
      err = RubyLLM::ConfigurationError.new("Missing configuration for OpenRouter: openrouter_api_key")
      c = described_class.classify(err)
      expect(c.reason).to eq(FR::AUTH)
      expect(c.retryable).to be false
    end

    it "our 'Missing API key for provider' error -> auth, NOT retryable" do
      err = Rubino::Error.new("Missing API key for provider 'minimax'. Set providers.minimax.api_key ...")
      c = described_class.classify(err)
      expect(c.reason).to eq(FR::AUTH)
      expect(c.retryable).to be false
    end

    it "a 'no api key' style message -> NOT retryable" do
      expect(described_class.retryable?(StandardError.new("no API key is set"))).to be false
    end
  end

  describe ".classify — unknown is the retryable default" do
    it "a generic no-status error -> unknown, retryable" do
      c = described_class.classify(RubyLLM::Error.new(nil, "something specific went wrong"))
      expect(c.reason).to eq(FR::UNKNOWN)
      expect(c.retryable).to be true
    end

    it "a bare StandardError -> retryable" do
      expect(described_class.retryable?(StandardError.new("totally generic"))).to be true
    end
  end

  describe ".classify — local Ruby programming errors are NOT retryable" do
    # A bug in our own code (or a caller's) reaches the classifier only because
    # the runner rescues StandardError broadly around the boundary; it must
    # propagate immediately, not retry behind backoff.
    [
      NoMethodError.new("undefined method 'ioctl'"),
      ArgumentError.new("wrong number of arguments"),
      TypeError.new("no implicit conversion"),
      NameError.new("uninitialized constant"),
      NotImplementedError.new("not done yet")
    ].each do |error|
      it "#{error.class} -> unknown, NOT retryable" do
        c = described_class.classify(error)
        expect(c.reason).to eq(FR::UNKNOWN)
        expect(c.retryable).to be false
      end
    end

    it "does NOT regress provider blips: a free-text 5xx with no status stays retryable" do
      expect(described_class.retryable?(StandardError.new("502 bad gateway"))).to be true
    end

    it "does NOT regress typed provider errors: RubyLLM::ServerError stays retryable" do
      expect(described_class.retryable?(ruby_llm_error(RubyLLM::ServerError, 500, "boom"))).to be true
    end

    it "RuntimeError is deliberately excluded — too generic, stays on the retryable default" do
      expect(described_class.retryable?(RuntimeError.new("transient"))).to be true
    end
  end

  describe ".http_status" do
    it "reads the wrapped Faraday response status" do
      expect(described_class.http_status(ruby_llm_error(RubyLLM::Error, 503, "x"))).to eq(503)
    end

    it "returns nil for a statusless error" do
      expect(described_class.http_status(StandardError.new("x"))).to be_nil
    end
  end
end
