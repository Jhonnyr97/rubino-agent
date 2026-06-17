# frozen_string_literal: true

# #487: the general sub-agent persona used to say only "do not ask follow-up
# questions… make the reasonable call" and NEVER named `ask_parent`. A spawned
# subagent quoted that to REFUSE escalating a genuine human-only decision,
# making ask_parent escalation unreliable (and undermining the 0.5.1 auto-open
# dropdown that only fires when a child actually calls ask_parent). The persona
# must reconcile the two: keep "don't pester with trivial questions / make
# reasonable low-stakes calls" BUT explicitly tell the subagent to use
# `ask_parent` for a genuinely human-only / high-stakes / unrecoverable decision.
RSpec.describe "general sub-agent escalation guidance (#487)" do # rubocop:disable RSpec/DescribeClass
  subject(:prompt) { Rubino::Agent::AgentRegistry.new.find("general").system_prompt }

  it "keeps the don't-pester-on-low-stakes guidance" do
    expect(prompt).to match(/low-stakes/i)
    expect(prompt).to match(/reasonable.+call/im)
  end

  it "names the ask_parent tool for genuine escalation" do
    expect(prompt).to include("ask_parent")
  end

  it "tells the subagent to escalate human-only / high-stakes / unrecoverable decisions" do
    expect(prompt).to match(/human-only|high-stakes|unrecoverable/i)
    # The escalation must be an instruction to USE the tool, not a prohibition.
    # The wording can wrap across lines, so normalize whitespace before matching.
    expect(prompt.gsub(/\s+/, " ")).to match(/use the `ask_parent` tool|use `ask_parent`/i)
  end
end
