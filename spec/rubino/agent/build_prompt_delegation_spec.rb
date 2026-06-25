# frozen_string_literal: true

# #subagent-delegation: some models (incl. the test MiniMax-M3) refuse to
# delegate, confabulating that "subagents have no task tool" — which is FALSE
# (the general subagent is tools: :all). The build persona's [Delegation]
# section must assert plainly that subagents DO have `task` so the model stops
# declining on a fabricated limitation. It must NOT promise an ask-the-parent
# channel: subagents are non-blocking background workers and cannot ask back.
RSpec.describe "build persona delegation guidance (#subagent-delegation)" do # rubocop:disable RSpec/DescribeClass
  subject(:prompt) { Rubino::Agent::AgentRegistry.new.find("build").system_prompt }

  it "states that subagents have the task tool available" do
    expect(prompt).to match(/subagent.*lacks `task`.*false/im)
  end

  it "confirms the general subagent has every tool (so delegation is never refused)" do
    expect(prompt).to match(/general subagent has every tool/i)
  end

  it "does not promise a child->parent ask channel" do
    expect(prompt).not_to include("ask_parent")
  end
end
