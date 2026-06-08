# frozen_string_literal: true

# LIVE MiniMax smoke test for the prefill-to-continue cure (Slice 5, rung 4).
#
# This calls the real MiniMax /anthropic endpoint, so it is GATED behind
# LIVE_MINIMAX=1 and NEVER runs in the default suite / CI. It reads the same
# ~/.rubino/config.yml + .env the CLI uses (MINIMAX_API_KEY), so no key is
# hard-coded or printed here.
#
# What it proves: MiniMax-M2.7 in manual-thinking mode tends to return a
# thinking-only ("completed but empty") turn first — the symptom that broke the
# gem before this slice. The DegenerateResponseRecovery ladder re-issues the
# SAME request with the model's reasoning seated as an assistant PREFILL, and the
# model continues into visible text. We assert the final response is non-empty
# once <think> is stripped.
#
#   LIVE_MINIMAX=1 bundle exec rspec \
#     spec/rubino/agent/degenerate_recovery_live_minimax_spec.rb
RSpec.describe "LIVE MiniMax prefill-to-continue cure", :live do
  before do
    skip "set LIVE_MINIMAX=1 to run the live MiniMax smoke test" unless ENV["LIVE_MINIMAX"] == "1"
  end

  it "finishes a thinking-only turn via prefill instead of returning empty" do
    # The default suite pins RUBINO_HOME to a throwaway test home (see
    # spec_helper). Point at the REAL ~/.rubino so we read the live MiniMax
    # provider config + .env key — never the empty test config (which would fall
    # back to OpenRouter and 401).
    real_home = ENV["RUBINO_REAL_HOME"] || File.expand_path("~/.rubino")
    config = Rubino::Config::Configuration.new(home_path: real_home)
    adapter = Rubino::LLM::RubyLLMAdapter.new(
      model_id: config.model_default,
      provider: config.model_provider,
      config:   config,
      ui:       Rubino::UI::Null.new,
      event_bus: Rubino::Interaction::EventBus.new
    )

    runner = Rubino::Agent::ModelCallRunner.new(
      llm:       adapter,
      config:    config,
      ui:        Rubino::UI::Null.new,
      event_bus: Rubino::Interaction::EventBus.new
    )

    # A prompt that biases the model toward heavy reasoning before answering —
    # the kind that surfaces a thinking-only first turn on MiniMax.
    request = Rubino::LLM::Request.new(
      messages: [
        { role: "user",
          content: "Think step by step, then give ONLY the final integer answer: " \
                   "what is 17 * 23? Reason carefully before answering." }
      ],
      stream: false
    )

    response = runner.call!(request, iteration: 1)
    visible  = Rubino::Agent::ResponseValidator.new
    expect(visible.degenerate?(response)).to be(false),
      "expected a non-degenerate final response after the prefill ladder, " \
      "got content=#{response.content.inspect}"
    expect(response.content.to_s).to match(/391/)
  end
end
