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

    it "ContextLengthExceededError -> context_overflow, not retryable" do
      c = described_class.classify(ruby_llm_error(RubyLLM::ContextLengthExceededError, 429, "context length exceeded"))
      expect(c.reason).to eq(FR::CONTEXT_OVERFLOW)
      expect(c.retryable).to be false
    end

    it "auth errors are classified as auth" do
      c = described_class.classify(ruby_llm_error(RubyLLM::UnauthorizedError, 401, "no"))
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

    # #417: ruby_llm raises a statusless ModelNotFoundError ("Unknown model: …")
    # BEFORE any HTTP call when the configured model id isn't registered. It used
    # to fall through to the unknown->retryable default and burn ~73s of backoff
    # on a config error that can NEVER succeed. It must fail fast (non-retryable).
    it "ModelNotFoundError (statusless config error) -> non-retryable, fails fast (#417)" do
      c = described_class.classify(RubyLLM::ModelNotFoundError.new("Unknown model: gpt-bogus"))
      expect(c.reason).to eq(FR::MODEL_NOT_FOUND)
      expect(c.retryable).to be false
      expect(described_class.retryable?(RubyLLM::ModelNotFoundError.new("Unknown model: x"))).to be false
    end

    it "a statusless 'unknown model' message -> non-retryable too (#417)" do
      c = described_class.classify(RuntimeError.new("The model 'foo' is not a valid model id"))
      expect(c.reason).to eq(FR::MODEL_NOT_FOUND)
      expect(c.retryable).to be false
    end

    it "400 with a context-overflow phrase -> context_overflow" do
      c = described_class.classify(ruby_llm_error(RubyLLM::Error, 400, "prompt is too long for context window"))
      expect(c.reason).to eq(FR::CONTEXT_OVERFLOW)
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

  # Regression #98: a provider's media/image validation rejection is PERMANENT
  # (the same attachment fails identically on every retry) but arrives
  # statusless from the MiniMax Anthropic-compat endpoint, so it used to fall
  # through to the unknown→retryable default and burn all 5 retries (~80s).
  describe ".classify — invalid media rejection is not retryable (#98)" do
    [
      "media exceeds size limit: max 10485760 bytes",
      "invalid param: invalid image content: decode image config: image: unknown format"
    ].each do |message|
      it "no-status #{message[0, 30].inspect}… -> format_error, not retryable" do
        c = described_class.classify(RubyLLM::Error.new(nil, message))
        expect(c.reason).to eq(FR::FORMAT_ERROR)
        expect(c.retryable).to be false
      end
    end

    it "stays non-retryable even when wrapped in a 5xx-class error" do
      err = ruby_llm_error(RubyLLM::ServerError, 500, "media exceeds size limit: max 10485760 bytes")
      expect(described_class.retryable?(err)).to be false
    end
  end

  # Regression #356: a PERMANENT context-overflow can arrive DISGUISED as a 5xx
  # — MiniMax wraps the "context window exceeds limit" 400 in a
  # RubyLLM::ServerError. The blanket ServerError→retryable branch used to win
  # because classify_typed matched the class BEFORE the context-overflow message
  # check, so a fail-fast/compress error was retried 5× (~133s) on a request
  # that fails identically every time. Now the overflow check runs FIRST.
  describe ".classify — context-overflow disguised as 5xx is not retryable (#356)" do
    it "ServerError whose message mentions the context window -> context_overflow, not retryable" do
      err = ruby_llm_error(RubyLLM::ServerError, 500, "internal error: context window exceeds limit")
      c = described_class.classify(err)
      expect(c.reason).to eq(FR::CONTEXT_OVERFLOW)
      expect(c.retryable).to be false
    end

    it "OverloadedError wrapping a context-overflow phrase is also non-retryable" do
      err = ruby_llm_error(RubyLLM::OverloadedError, 529, "prompt is too long for context window")
      c = described_class.classify(err)
      expect(c.reason).to eq(FR::CONTEXT_OVERFLOW)
      expect(c.retryable).to be false
    end

    it "a plain ServerError with NO overflow phrase still stays retryable (no regression)" do
      err = ruby_llm_error(RubyLLM::ServerError, 500, "internal server error")
      c = described_class.classify(err)
      expect(c.reason).to eq(FR::SERVER_ERROR)
      expect(c.retryable).to be true
    end
  end

  # Regression #361(a): an UNRESOLVABLE host is a PERMANENT misconfiguration
  # (a typo'd base_url) — every retry re-runs the same DNS lookup and fails
  # identically, so retrying burns the whole budget (~81s). faraday-net_http
  # wraps the resolver's SocketError in a Faraday::ConnectionFailed, so a naive
  # "any ConnectionFailed is retryable" classified it as transient. Now a DNS
  # failure phrasing fails fast.
  describe ".classify — unresolvable host fails fast (#361a)" do
    # PERMANENT resolver errors (EAI_NONAME — the host genuinely doesn't exist,
    # e.g. a typo'd base_url) fail fast: every retry re-runs the same lookup.
    [
      "Failed to open TCP connection: getaddrinfo: Name or service not known",
      "getaddrinfo: nodename nor servname provided, or not known"
    ].each do |message|
      it "#{message[0, 30].inspect}… -> not retryable" do
        err = Faraday::ConnectionFailed.new(message)
        c = described_class.classify(err)
        expect(c.retryable).to be false
        expect(c.reason).to eq(FR::FORMAT_ERROR)
      end
    end

    it "a bare SocketError-style getaddrinfo message also fails fast" do
      expect(described_class.retryable?(SocketError.new("getaddrinfo: Name or service not known"))).to be false
    end

    # TRANSIENT resolver error (EAI_AGAIN) — the resolver was momentarily
    # unavailable (a getaddrinfo storm when several subagents dial the same host
    # at once). The next lookup usually works, so it MUST retry, not fail fast.
    it "a TEMPORARY name-resolution failure is retryable (EAI_AGAIN, not a typo'd host)" do
      err = Faraday::ConnectionFailed.new("getaddrinfo: Temporary failure in name resolution")
      c = described_class.classify(err)
      expect(c.retryable).to be true
      expect(described_class.retryable?(SocketError.new("Temporary failure in name resolution"))).to be true
    end

    it "a genuine transient transport blip still retries (no over-broadening)" do
      expect(described_class.retryable?(Faraday::ConnectionFailed.new("connection reset by peer"))).to be true
      expect(described_class.retryable?(Faraday::ConnectionFailed.new("end of file reached"))).to be true
    end
  end

  # Regression #327(b): a deterministic 4xx request-validation rejection
  # ("invalid params" / "invalid request") that some providers surface
  # STATUSLESS used to fall through to unknown→retryable and burn the whole
  # api_max_retries:5 backoff (~85s) on a request that fails identically every
  # time. Now it fails fast as a permanent FORMAT_ERROR.
  describe ".classify — invalid-params/request validation is not retryable (#327)" do
    [
      "invalid params: the thinking budget is not supported by this model",
      "invalid request: messages[0].role must be one of user|assistant",
      "Unprocessable Entity: temperature must be <= 2",
      'API request failed: {"error":{"type":"invalid_request_error","message":"bad tool schema"}}'
    ].each do |message|
      it "no-status #{message[0, 28].inspect}… -> format_error, not retryable" do
        c = described_class.classify(RubyLLM::Error.new(nil, message))
        expect(c.reason).to eq(FR::FORMAT_ERROR)
        expect(c.retryable).to be false
      end
    end

    it "surfaces the offending field in the classified message" do
      c = described_class.classify(RubyLLM::Error.new(nil, "invalid params: temperature out of range"))
      expect(c.message).to include("temperature")
    end

    it "a 400 'invalid params' is permanent via the status path too" do
      err = ruby_llm_error(RubyLLM::BadRequestError, 400, "invalid params: bad field")
      expect(described_class.retryable?(err)).to be false
    end

    # A context-overflow phrased with an "invalid request" prefix must NOT be
    # captured by the new invalid-params fail-fast bucket (that would turn a
    # compressible overflow into a permanent format_error). The invalid_params
    # classifier defers on any context-overflow phrasing, so behaviour is
    # unchanged from before this fix (statusless overflow stays unknown).
    it "does NOT misclassify a context-overflow phrased as an invalid request" do
      msg = "invalid request: prompt is too long for the context window"
      c = described_class.classify(RubyLLM::Error.new(nil, msg))
      expect(c.reason).not_to eq(FR::FORMAT_ERROR)
    end

    # Regression: a TRANSIENT mid-stream blip that MiniMax emits with the generic
    # text "invalid params" is re-raised by ruby_llm's streaming path as a
    # ServerError(500) (parse_streaming_error hard-codes status 500). Bisecting a
    # captured failing request proved the request itself is VALID (it replays 200
    # against MiniMax every time), so this must stay on the retryable SERVER_ERROR
    # path — NOT be clobbered into a permanent FORMAT_ERROR by its message text,
    # which killed the whole multi-tool turn with no retry.
    it "a 5xx-wrapped 'invalid params' (streaming transient) stays retryable SERVER_ERROR" do
      err = ruby_llm_error(RubyLLM::ServerError, 500, "invalid params")
      c = described_class.classify(err)
      expect(c.reason).to eq(FR::SERVER_ERROR)
      expect(c.retryable).to be true
    end

    it "ServiceUnavailable/Overloaded wrapping 'invalid request' also stays retryable" do
      expect(described_class.classify(ruby_llm_error(RubyLLM::ServiceUnavailableError, 503,
                                                     "invalid request")).retryable).to be true
      expect(described_class.classify(ruby_llm_error(RubyLLM::OverloadedError, 529,
                                                     "invalid params")).retryable).to be true
    end

    # The fail-fast contract is preserved for a GENUINE 4xx rejection: a real
    # BadRequestError(400) "invalid params" is a deterministic request rejection
    # and still fails fast (the 5xx carve-out must not weaken #327).
    it "a real 400 BadRequestError 'invalid params' still fails fast (no regression)" do
      err = ruby_llm_error(RubyLLM::BadRequestError, 400, "invalid params: bad field")
      c = described_class.classify(err)
      expect(c.reason).to eq(FR::FORMAT_ERROR)
      expect(c.retryable).to be false
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

  # #126: a PRESENT but INVALID key rejected via a statusless provider body
  # (MiniMax "login fail") used to fall through to unknown->retryable and burn
  # ~60-90s of silent retries on a deterministic auth failure.
  describe ".classify — invalid credential fails fast (#126)" do
    it "MiniMax statusless 'login fail' body -> auth, NOT retryable" do
      err = RubyLLM::Error.new(nil, "login fail: Please carry the API secret key in the 'X-Api-Key' field")
      c = described_class.classify(err)
      expect(c.reason).to eq(FR::AUTH)
      expect(c.retryable).to be false
      expect(c.auth?).to be true
    end

    it "an 'incorrect api key' style message -> auth, NOT retryable" do
      c = described_class.classify(StandardError.new("Incorrect API key provided: sk-cp-broken"))
      expect(c.reason).to eq(FR::AUTH)
      expect(c.retryable).to be false
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

  # Bug B (#WHATIF): a MiniMax HTTP 429 quota error reaches the STREAMING path,
  # where ruby_llm's anthropic-compat parser re-wraps it as a 400 BadRequestError
  # carrying the generic default message "Invalid request - please check your
  # input". The original "rate_limit_error / Token Plan usage limit reached"
  # signal survives ONLY in the response body, so the classifier must read the
  # body — not just the clobbered message — to recover the rate-limit category.
  describe ".classify — rate-limit mis-shaped on the streaming path (Bug B)" do
    # message != body, the way the clobbered-429 case actually arrives.
    def err_with_body(klass, status, message, body)
      response = double("FaradayResponse", status: status, body: body, headers: {})
      klass.new(response, message)
    end

    it "classifies a 429 clobbered to a 400 BadRequestError as RATE_LIMIT via the body" do
      e = err_with_body(
        RubyLLM::BadRequestError, 400,
        "Invalid request - please check your input",
        '{"type":"rate_limit_error","message":"Token Plan usage limit reached, check your plan"}'
      )
      c = described_class.classify(e)
      expect(c.reason).to eq(FR::RATE_LIMIT)
      expect(c.retryable).to be true
    end

    it "still classifies a GENUINE 400 (no rate-limit signal) as FORMAT_ERROR" do
      e = err_with_body(
        RubyLLM::BadRequestError, 400,
        "Invalid request - please check your input",
        '{"error":{"message":"malformed json near token 5"}}'
      )
      c = described_class.classify(e)
      expect(c.reason).to eq(FR::FORMAT_ERROR)
      expect(c.retryable).to be false
    end

    it "recognises the bare 'Token Plan usage limit reached' phrasing" do
      e = err_with_body(RubyLLM::Error, nil, "Token Plan usage limit reached", "Token Plan usage limit reached")
      expect(described_class.classify(e).reason).to eq(FR::RATE_LIMIT)
    end

    it "keeps a typed RubyLLM::RateLimitError on the rate-limit path" do
      c = described_class.classify(ruby_llm_error(RubyLLM::RateLimitError, 429, "Rate limit exceeded"))
      expect(c.reason).to eq(FR::RATE_LIMIT)
      expect(c.retryable).to be true
    end

    it "does NOT mis-tag a real context-overflow as a rate limit" do
      e = ruby_llm_error(RubyLLM::Error, 400, "prompt is too long: maximum context length exceeded")
      expect(described_class.classify(e).reason).to eq(FR::CONTEXT_OVERFLOW)
    end
  end
end
