# frozen_string_literal: true

RSpec.describe Rubino::Agent::ModelCallRunner do
  # ── Scripted boundary ───────────────────────────────────────────────────
  # A minimal stand-in for the LLM boundary (#call(request) { |chunk| }). Each
  # scripted item is either an AdapterResponse (returned) or an Exception
  # (raised) — consumed in order, one per attempt. No network, no ruby_llm.
  class ScriptedBoundary
    attr_reader :calls

    def initialize(*script)
      @script = script
      @calls  = 0
    end

    def call(_request)
      @calls += 1
      item = @script.shift
      raise "ScriptedBoundary exhausted" if item.nil? && @script.empty? && @calls > 1
      raise item if item.is_a?(Exception)

      item
    end
  end

  # Records every request it is handed, so a spec can assert what reached the
  # boundary on the re-issue (e.g. the prefill seed on rung 4).
  class RecordingBoundary
    attr_reader :requests, :calls

    def initialize(*script)
      @script   = script
      @requests = []
      @calls    = 0
    end

    def call(request)
      @calls += 1
      @requests << request
      item = @script.shift
      raise item if item.is_a?(Exception)

      item
    end
  end

  def text_response(content = "the answer")
    Rubino::LLM::AdapterResponse.new(
      content: content, tool_calls: [], input_tokens: 1, output_tokens: 1, model_id: "fake"
    )
  end

  def thinking_only_response(content = "<think>reasoning, no answer</think>")
    Rubino::LLM::AdapterResponse.new(
      content: content, tool_calls: [], input_tokens: 1, output_tokens: 1, model_id: "fake"
    )
  end

  def empty_response
    Rubino::LLM::AdapterResponse.new(
      content: nil, tool_calls: [], input_tokens: 1, output_tokens: 0, model_id: "fake"
    )
  end

  def interrupted_response(content = "partial")
    Rubino::LLM::AdapterResponse.new(
      content: content, tool_calls: [], input_tokens: 1, output_tokens: 1,
      model_id: "fake", interrupted: true
    )
  end

  # A retryable transient error (transport drop → TIMEOUT, retryable).
  def transient_error(message = "end of file reached")
    Faraday::ConnectionFailed.new(message)
  end

  # A permanent error (400 format error → not retryable). Built with a Faraday
  # response double so ErrorClassifier reads the 400 status.
  def permanent_error(status = 400, message = "bad request")
    response = double("FaradayResponse", status: status, body: message, headers: {})
    RubyLLM::Error.new(response, message)
  end

  let(:ui)        { Rubino::UI::Null.new }
  let(:event_bus) { Rubino::Interaction::EventBus.new }
  let(:config)    { test_configuration("agent" => { "api_max_retries" => 3, "empty_response_max_retries" => 2 }) }
  let(:request) { Rubino::LLM::Request.new(messages: [{ role: "user", content: "hi" }]) }

  def build_runner(llm, cancel_token: nil, cfg: config)
    described_class.new(
      llm: llm,
      config: cfg,
      ui: ui,
      event_bus: event_bus,
      cancel_token: cancel_token
    )
  end

  # Never actually wait between attempts in specs.
  before { allow_any_instance_of(Rubino::Agent::BackoffPolicy).to receive(:sleep) }

  # ── Happy path ──────────────────────────────────────────────────────────
  describe "valid response on the first try" do
    it "returns it without retrying" do
      boundary = ScriptedBoundary.new(text_response("done"))
      out = build_runner(boundary).call!(request)
      expect(out.content).to eq("done")
      expect(boundary.calls).to eq(1)
    end

    it "forwards the streaming block to the boundary unchanged" do
      forwarded = nil
      boundary = Object.new
      boundary.define_singleton_method(:call) do |_req, &blk|
        blk&.call({ type: :content, text: "hi", message_id: 0 })
        Rubino::LLM::AdapterResponse.new(content: "hi", tool_calls: [], input_tokens: 1,
                                         output_tokens: 1, model_id: "fake")
      end
      build_runner(boundary).call!(request) { |chunk| forwarded = chunk }
      expect(forwarded).to eq({ type: :content, text: "hi", message_id: 0 })
    end
  end

  # ── Transient error → retry → succeed ───────────────────────────────────
  describe "transient (retryable) error" do
    it "retries with backoff then returns the eventual valid response" do
      boundary = ScriptedBoundary.new(transient_error, transient_error, text_response("recovered"))
      out = build_runner(boundary).call!(request)
      expect(out.content).to eq("recovered")
      expect(boundary.calls).to eq(3) # 1 initial + 2 retries
    end

    it "raises the error once api_max_retries is exhausted" do
      cfg = test_configuration("agent" => { "api_max_retries" => 2 })
      boundary = ScriptedBoundary.new(transient_error, transient_error, transient_error)
      expect { build_runner(boundary, cfg: cfg).call!(request) }
        .to raise_error(Faraday::ConnectionFailed)
      expect(boundary.calls).to eq(3) # 1 initial + 2 retries, then give up
    end
  end

  # ── Permanent error → raise immediately ─────────────────────────────────
  describe "permanent (non-retryable) error" do
    it "re-raises without retrying" do
      boundary = ScriptedBoundary.new(permanent_error(400))
      expect { build_runner(boundary).call!(request) }.to raise_error(RubyLLM::Error)
      expect(boundary.calls).to eq(1)
    end

    it "upgrades an auth error to the actionable hint" do
      boundary = ScriptedBoundary.new(permanent_error(401, "Invalid API key"))
      expect { build_runner(boundary).call!(request) }
        .to raise_error(Rubino::Error, /Token may have expired/)
      expect(boundary.calls).to eq(1)
    end

    # A local Ruby bug raised by the boundary (e.g. a NoMethodError from a UI
    # shim mid-turn) must NOT be retried — it is a programming error, not a
    # provider blip. It propagates immediately so the bug surfaces instead of
    # being masked by a retry storm of llm.retry warnings.
    it "does NOT retry a local NoMethodError — re-raises after one call" do
      boundary = ScriptedBoundary.new(NoMethodError.new("undefined method 'ioctl'"))
      expect { build_runner(boundary).call!(request) }.to raise_error(NoMethodError)
      expect(boundary.calls).to eq(1)
    end
  end

  # ── Empty response → retry → EmptyModelResponseError ────────────────────
  describe "empty (200-OK-but-nothing) response" do
    it "retries up to empty_response_max_retries then raises EmptyModelResponseError" do
      boundary = ScriptedBoundary.new(empty_response, empty_response, empty_response)
      expect { build_runner(boundary).call!(request, iteration: 1) }
        .to raise_error(Rubino::EmptyModelResponseError)
      expect(boundary.calls).to eq(3) # 1 initial + 2 retries (default budget)
    end

    it "recovers when a retry returns real content" do
      boundary = ScriptedBoundary.new(empty_response, text_response("finally"))
      out = build_runner(boundary).call!(request)
      expect(out.content).to eq("finally")
      expect(boundary.calls).to eq(2)
    end

    it "honors a custom empty_response_max_retries" do
      cfg = test_configuration("agent" => { "empty_response_max_retries" => 1 })
      boundary = ScriptedBoundary.new(empty_response, empty_response)
      expect { build_runner(boundary, cfg: cfg).call!(request) }
        .to raise_error(Rubino::EmptyModelResponseError)
      expect(boundary.calls).to eq(2) # 1 initial + 1 retry
    end
  end

  # ── Degenerate (thinking-only) → prefill-to-continue ladder (Slice 5) ────
  describe "thinking-only (degenerate) response → prefill-to-continue" do
    it "re-issues with the prefill seed and returns the recovered text" do
      boundary = RecordingBoundary.new(thinking_only_response, text_response("Here is the answer."))
      out = build_runner(boundary).call!(request, iteration: 1)

      expect(out.content).to eq("Here is the answer.")
      expect(boundary.calls).to eq(2)
      # The SECOND (re-issued) request carries the model's own reasoning as the
      # assistant prefill seed so it continues into visible content.
      expect(boundary.requests[0].prefill).to be_nil
      expect(boundary.requests[1].prefill).to eq("reasoning, no answer")
    end

    it "prefills at most twice, then falls to empty-retry, then raises" do
      # 1 thinking-only + 1 thinking-only (2 prefills) + empties to exhaust the
      # empty budget (2 by config) → EmptyModelResponseError.
      boundary = RecordingBoundary.new(
        thinking_only_response, thinking_only_response, empty_response, empty_response, empty_response
      )
      expect { build_runner(boundary).call!(request, iteration: 1) }
        .to raise_error(Rubino::EmptyModelResponseError)
      # 1 initial + 2 prefill re-issues + 2 empty retries = 5 calls.
      expect(boundary.calls).to eq(5)
      expect(boundary.requests[1].prefill).not_to be_nil
      expect(boundary.requests[2].prefill).not_to be_nil
    end
  end

  # ── Post-tool empty nudge (rung 3) ───────────────────────────────────────
  describe "empty response after a tool round → nudge" do
    it "appends a continue-nudge to the request messages and re-issues" do
      messages = [{ role: "user", content: "do it" },
                  { role: "assistant", content: "", tool_calls: [{ id: "1", name: "shell" }] },
                  { role: "tool", content: "ok", tool_call_id: "1" }]
      req = Rubino::LLM::Request.new(messages: messages)
      boundary = RecordingBoundary.new(empty_response, text_response("continued"))

      out = build_runner(boundary).call!(req, iteration: 1)
      expect(out.content).to eq("continued")
      # The nudge was appended in place: …tool → assistant("(empty)") → user(nudge).
      expect(messages[-2]).to include(role: "assistant")
      expect(messages.last).to include(role: "user")
      expect(messages.last[:content]).to include("continue with the task")
    end
  end

  # ── Partial-stream recovery (rung 1) ─────────────────────────────────────
  describe "partial-stream recovery" do
    it "uses content already streamed to the user when the turn comes back degenerate" do
      # Boundary streams real visible text to the block, then returns a
      # thinking-only response (the connection died after the visible content).
      boundary = Object.new
      boundary.define_singleton_method(:call) do |_req, &blk|
        blk&.call({ type: :content, text: "The streamed answer.", message_id: 0 })
        Rubino::LLM::AdapterResponse.new(content: "<think>reasoning</think>", tool_calls: [],
                                         input_tokens: 1, output_tokens: 1, model_id: "fake")
      end
      out = build_runner(boundary).call!(request, iteration: 1) { |_c| }
      expect(out.content).to eq("The streamed answer.")
    end
  end

  # ── Interrupted / nil response handed back untouched ────────────────────
  describe "structurally-invalid-but-not-empty response" do
    it "returns an interrupted partial as-is (the Loop maps it to StreamInterruptedError)" do
      boundary = ScriptedBoundary.new(interrupted_response("half"))
      out = build_runner(boundary).call!(request)
      expect(out.interrupted?).to be true
      expect(boundary.calls).to eq(1) # not retried
    end
  end

  # ── Cancellation ────────────────────────────────────────────────────────
  describe "cancellation" do
    it "aborts mid-backoff when the token is cancelled" do
      token = Rubino::Interaction::CancelToken.new
      # First attempt raises a transient error; BackoffPolicy#sleep then checks
      # the token. Cancel it so the wait raises Interrupted instead of retrying.
      allow_any_instance_of(Rubino::Agent::BackoffPolicy)
        .to receive(:sleep).and_raise(Rubino::Interrupted)
      boundary = ScriptedBoundary.new(transient_error, text_response("never reached"))
      expect { build_runner(boundary, cancel_token: token).call!(request) }
        .to raise_error(Rubino::Interrupted)
      expect(boundary.calls).to eq(1) # cancelled during the backoff after attempt 1
    end

    it "never retries a user Interrupted raised by the boundary" do
      boundary = ScriptedBoundary.new(Rubino::Interrupted.new)
      expect { build_runner(boundary).call!(request) }.to raise_error(Rubino::Interrupted)
      expect(boundary.calls).to eq(1)
    end

    # D4: a Ctrl+C that lands mid-stream may not raise — once a chunk has flowed
    # the adapter RETURNS the buffered (here empty) partial. With the token
    # cancelled, the runner must treat that as the terminal interrupt, NOT
    # classify it :empty_response and emit "Empty response — retrying (1/2)".
    it "raises Interrupted (no empty-retry) when the token was cancelled mid-stream" do
      token = Rubino::Interaction::CancelToken.new
      # A boundary that, on its FIRST call, trips the cancel token DURING the
      # stream (as the user's Ctrl+C does) and then RETURNS an empty partial —
      # the adapter's "chunks flowed, so return buffered" path, which does not
      # raise. The runner must re-check the token after the call and raise the
      # terminal interrupt instead of classifying the empty partial as retryable.
      calls = 0
      empty = empty_response
      boundary = Object.new
      boundary.define_singleton_method(:call) do |_req, &blk|
        calls += 1
        blk&.call({ type: :content, text: "par", message_id: 0 })
        token.cancel! # Ctrl+C landed mid-stream
        empty
      end
      boundary.define_singleton_method(:calls) { calls }

      runner = build_runner(boundary, cancel_token: token)
      expect { runner.call!(request, iteration: 1) }.to raise_error(Rubino::Interrupted)
      expect(boundary.calls).to eq(1) # NO empty-retry re-issue
      # The spurious banner is the real symptom: the recovery ladder must never
      # have run, so no "Empty response — retrying" note was emitted.
      retry_notes = ui.messages.select { |m| m[:message].to_s.include?("Empty response from model — retrying") }
      expect(retry_notes).to be_empty
    end
  end

  # ── SLICE-7: provider/model fallback ──────────────────────────────────────
  # A test double for Agent::FallbackChain: holds an ordered list of boundaries
  # (primary first). #activate_next! advances to the next, mirroring the real
  # chain's contract (true while it switches, false when exhausted). The runner
  # reads #current_adapter each attempt, so a switch takes effect on the next call.
  class FakeChain
    attr_reader :switches

    def initialize(*boundaries)
      @boundaries = boundaries
      @index      = 0
      @switches   = 0
    end

    def current_adapter
      @boundaries[@index]
    end

    def activate_next!
      return false if @index >= @boundaries.size - 1

      @index    += 1
      @switches += 1
      true
    end
  end

  def build_runner_with_chain(chain, cfg: config)
    described_class.new(
      llm: chain.current_adapter,
      fallback_chain: chain,
      config: cfg,
      ui: ui,
      event_bus: event_bus,
      cancel_token: nil
    )
  end

  describe "fallback chain (Slice 7)" do
    it "eager-falls back on an invalid (interrupted) response, then succeeds on the fallback" do
      primary  = ScriptedBoundary.new(interrupted_response("partial"))
      fallback = ScriptedBoundary.new(text_response("answer from fallback"))
      chain    = FakeChain.new(primary, fallback)

      out = build_runner_with_chain(chain).call!(request)
      expect(out.content).to eq("answer from fallback")
      expect(chain.switches).to eq(1)
      expect(primary.calls).to eq(1)
      expect(fallback.calls).to eq(1)
    end

    it "returns the invalid response untouched when the chain is exhausted (no switch)" do
      primary = ScriptedBoundary.new(interrupted_response("partial"))
      chain   = FakeChain.new(primary) # no fallback available
      out = build_runner_with_chain(chain).call!(request)
      expect(out.interrupted?).to be(true)
      expect(chain.switches).to eq(0)
    end

    it "falls back when the error-retry budget is exhausted, then resets and retries" do
      cfg      = test_configuration("agent" => { "api_max_retries" => 1 })
      # primary: two transient errors (1 initial + 1 retry exhausts the budget)
      primary  = ScriptedBoundary.new(transient_error, transient_error)
      fallback = ScriptedBoundary.new(text_response("recovered on fallback"))
      chain    = FakeChain.new(primary, fallback)

      out = build_runner_with_chain(chain, cfg: cfg).call!(request)
      expect(out.content).to eq("recovered on fallback")
      expect(chain.switches).to eq(1)
      expect(primary.calls).to eq(2)   # initial + 1 retry, then budget exhausted → fallback
      expect(fallback.calls).to eq(1)
    end

    it "raises the classified error when exhausted AND the chain cannot switch" do
      cfg     = test_configuration("agent" => { "api_max_retries" => 0 })
      primary = ScriptedBoundary.new(transient_error)
      chain   = FakeChain.new(primary) # no fallback
      expect { build_runner_with_chain(chain, cfg: cfg).call!(request) }
        .to raise_error(Faraday::ConnectionFailed)
      expect(chain.switches).to eq(0)
    end

    it "rung 6: falls back after empty-retries are exhausted, then succeeds" do
      cfg = test_configuration("agent" => { "empty_response_max_retries" => 1 })
      # primary: empty twice (initial + 1 empty-retry exhausts), then ladder hits
      # rung 6 → fallback; fallback returns real text.
      primary  = ScriptedBoundary.new(empty_response, empty_response)
      fallback = ScriptedBoundary.new(text_response("real answer"))
      chain    = FakeChain.new(primary, fallback)

      out = build_runner_with_chain(chain, cfg: cfg).call!(request)
      expect(out.content).to eq("real answer")
      expect(chain.switches).to eq(1)
      expect(fallback.calls).to eq(1)
    end

    it "rung 7: raises EmptyModelResponseError when empty AND the chain cannot switch" do
      cfg     = test_configuration("agent" => { "empty_response_max_retries" => 1 })
      primary = ScriptedBoundary.new(empty_response, empty_response, empty_response)
      chain   = FakeChain.new(primary) # no fallback
      expect { build_runner_with_chain(chain, cfg: cfg).call!(request) }
        .to raise_error(Rubino::EmptyModelResponseError)
      expect(chain.switches).to eq(0)
    end
  end
end
