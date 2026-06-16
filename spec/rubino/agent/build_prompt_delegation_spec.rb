# frozen_string_literal: true

# #subagent-delegation: some models (incl. the test MiniMax-M3) refuse to
# delegate ask_parent tasks, confabulating that "subagents have no
# ask_parent/task tool" — which is FALSE (the general subagent is tools: :all).
# The build persona's [Delegation] section must assert plainly that subagents DO
# have those tools so the model stops declining on a fabricated limitation.
RSpec.describe "build persona delegation guidance (#subagent-delegation)" do
  subject(:prompt) { Rubino::Agent::AgentRegistry.new.find("build").system_prompt }

  it "states that subagents have the task and ask_parent tools available" do
    expect(prompt).to include("ask_parent")
    expect(prompt).to match(/subagent.*lacks `task`\/`ask_parent`.*false/im)
  end

  it "confirms the general subagent has every tool (so delegation is never refused)" do
    expect(prompt).to match(/general subagent has every tool/i)
  end
end
