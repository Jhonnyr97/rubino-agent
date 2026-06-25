# frozen_string_literal: true

# #487 / non-blocking subagents: the general sub-agent persona must keep the
# "don't pester with trivial questions / make reasonable low-stakes calls"
# guidance. Subagents are NON-BLOCKING background workers with no channel to
# ask the parent mid-task, so the persona must NOT name an `ask_parent` tool;
# instead it must tell the subagent to make the safe/reversible call and
# surface a genuinely human-only / high-stakes / unrecoverable decision in its
# result for the parent to resolve.
RSpec.describe "general sub-agent escalation guidance (#487)" do # rubocop:disable RSpec/DescribeClass
  subject(:prompt) { Rubino::Agent::AgentRegistry.new.find("general").system_prompt }

  it "keeps the don't-pester-on-low-stakes guidance" do
    expect(prompt).to match(/reasonable.+call/im)
  end

  it "does not name an ask_parent escalation tool" do
    expect(prompt).not_to include("ask_parent")
  end

  it "tells the subagent to surface human-only / high-stakes / unrecoverable decisions" do
    expect(prompt).to match(/human-only|high-stakes|unrecoverable/i)
    # The escalation must be "surface it in your result", not "call a tool".
    expect(prompt.gsub(/\s+/, " ")).to match(/surface the open decision|surface it/i)
  end
end
