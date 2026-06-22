# frozen_string_literal: true

# Regression guard for the duplicate-"finished" dedup.
#
# The idle non-blocking completion affordance (the old
# #surface_finished_subagents poll, which emitted
# `✓ sa_… finished — /agents <id> for the result`) was REMOVED: it
# re-announced every :completed background child that the agent-multiplexer
# worker marker — UI::CLI#subagent_finished → `✓ <id> · <name> · done`, emitted
# by TaskTool#record_completion at the terminal transition — already surfaces.
# The result was the SAME finish shown twice in the main timeline (the user's
# "ci sono finished, non si capisce" report). The worker marker is now the SOLE
# completion announcement; a finished child's result is viewed via the dropdown
# `↓ + Enter` drill-in.
RSpec.describe Rubino::CLI::ChatCommand do
  subject(:cmd) { described_class.new(provider: "fake", model: "fake/test") }

  it "no longer hosts the duplicate idle finished-affordance poll" do
    expect(cmd.private_methods).not_to include(:surface_finished_subagents)
  end
end
