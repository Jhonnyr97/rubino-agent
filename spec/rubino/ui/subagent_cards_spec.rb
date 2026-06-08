# frozen_string_literal: true

# UI::SubagentCards formats BackgroundTasks entries into the collapsed live
# CARD rows the parent shows while background subagents run (Variant A). Pure
# formatting — these specs build plain Entry structs and assert the rendered
# lines (ANSI stripped), the collapse cap, the overflow tail, and the
# approval-surfacing variant.
RSpec.describe Rubino::UI::SubagentCards do
  subject(:cards) { described_class.new(pastel: Pastel.new(enabled: false)) }

  def entry(**attrs)
    Rubino::Tools::BackgroundTasks::Entry.new(
      { id: "sa_1", subagent: "explore", status: :running,
        started_at: Time.now, tool_count: 0, activity_log: [] }.merge(attrs)
    )
  end

  def plain(lines)
    lines.map { |l| l.gsub(/\e\[[0-9;]*m/, "") }
  end

  it "renders nothing when no entries are live" do
    expect(cards.card_lines([])).to eq([])
    expect(cards.card_lines([entry(status: :completed)])).to eq([])
  end

  it "renders one collapsed card row per running subagent with the distinguishing activity" do
    e = entry(id: "sa_9ae4", tool_count: 14, last_activity: 'grep "def authenticate"',
              started_at: Time.now - 38)
    line = plain(cards.card_lines([e])).first
    expect(line).to include("▸ sa_9ae4 · explore · running · 14 tools")
    expect(line).to include('grep "def authenticate"')
  end

  it "stacks up to MAX_CARDS cards plus a single shared hint line" do
    es = Array.new(described_class::MAX_CARDS) { |i| entry(id: "sa_#{i}", last_activity: "step #{i}") }
    lines = plain(cards.card_lines(es))
    # MAX_CARDS card rows + 1 hint row.
    expect(lines.size).to eq(described_class::MAX_CARDS + 1)
    expect(lines.last).to include("/agents <id> to watch")
  end

  it "collapses overflow beyond MAX_CARDS into a +N more tail" do
    es = Array.new(described_class::MAX_CARDS + 2) { |i| entry(id: "sa_#{i}") }
    lines = plain(cards.card_lines(es))
    expect(lines.any? { |l| l.include?("+ 2 more") }).to be(true)
  end

  it "keeps concurrent tasks distinguishable by last_activity (#127)" do
    a = entry(id: "sa_a", last_activity: "read lib/auth/session.rb")
    b = entry(id: "sa_b", last_activity: 'shell "bundle exec rspec"')
    lines = plain(cards.card_lines([a, b]))
    expect(lines[0]).to include("read lib/auth/session.rb")
    expect(lines[1]).to include('shell "bundle exec rspec"')
  end

  describe "approval-surfacing card (Option 2)" do
    it "leads with the approval + command instead of the running line" do
      e = entry(id: "sa_x", status: :needs_approval, approval_command: "rm -rf build")
      line = plain(cards.card_lines([e])).first
      expect(line).to include("● sa_x · explore · needs approval: rm -rf build")
      expect(line).to include("/agents sa_x")
    end

    it "switches the hint to the approve affordance when something needs approval" do
      e = entry(id: "sa_x", status: :needs_approval, approval_command: "c")
      hint = plain(cards.card_lines([e])).last
      expect(hint).to include("/agents <id> to approve")
    end
  end
end
