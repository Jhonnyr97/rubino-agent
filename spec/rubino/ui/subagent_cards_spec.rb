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
    expect(lines.last).to include("↓ to navigate")
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
      expect(line).to include("↓ to approve")
    end

    it "switches the hint to the approve affordance when something needs approval" do
      e = entry(id: "sa_x", status: :needs_approval, approval_command: "c")
      hint = plain(cards.card_lines([e])).last
      expect(hint).to include("↓ to navigate")
    end

    # #141: a multi-line ruby/shell command often STARTS with a blank line —
    # `.lines.first` rendered an empty "needs approval:" body. The preview must
    # be the first NON-BLANK line.
    it "previews the first non-blank command line, never an empty body (#141)" do
      e = entry(id: "sa_x", status: :needs_approval,
                approval_command: "\n# Method 1: Iterative\nfib_iter = 1")
      line = plain(cards.card_lines([e])).first
      expect(line).to include("needs approval: # Method 1: Iterative")
      expect(line).not_to include("needs approval:  ")
      expect(line).not_to include("fib_iter")
    end
  end

  describe "aggregated ⛔N waiting-on-you count (#475-4)" do
    it "shows ⛔1 (singular) for one child blocked on the human" do
      e = entry(id: "sa_b", status: :blocked_on_human, ask_question: "sqlite or postgres?")
      hint = plain(cards.card_lines([e])).last
      expect(hint).to include("⛔1 subagent waiting on you")
      expect(hint).to include("↓ to navigate")
    end

    it "aggregates the count (pluralized) across several blocked children" do
      es = %w[sa_a sa_b].map { |id| entry(id: id, status: :blocked_on_human, ask_question: "q") }
      hint = plain(cards.card_lines(es)).last
      expect(hint).to include("⛔2 subagents waiting on you")
    end

    it "counts blocked children HIDDEN behind the MAX_CARDS overflow too" do
      # More blocked children than fit as cards: the aggregated count must still
      # reflect the TRUE total (counted over the full live list, not the shown cards).
      n  = described_class::MAX_CARDS + 2
      es = Array.new(n) { |i| entry(id: "sa_#{i}", status: :blocked_on_human, ask_question: "q") }
      hint = plain(cards.card_lines(es)).last
      expect(hint).to include("⛔#{n} subagents waiting on you")
    end
  end

  # #141: "· 1 tools ·" — the card must pluralize like the turn footer does.
  it "pluralizes the tool count (1 tool, 2 tools) (#141)" do
    one = plain(cards.card_lines([entry(tool_count: 1)])).first
    two = plain(cards.card_lines([entry(tool_count: 2)])).first
    expect(one).to include("· 1 tool ·")
    expect(two).to include("· 2 tools ·")
  end

  # CWE-150 (#564, same class as #563): a card's untrusted fields — last_activity
  # (built from a child's tool args, e.g. an attacker-named workspace file), the
  # model-chosen subagent NAME, an ask_parent question, an approval command — are
  # stored in BottomComposer#@cards and the live region paints them VERBATIM the
  # instant the subagent acts, with NO approval and NO user gesture. A raw
  # `\e[2J` (clear) / `\e]0;…\a` (OSC title) / `\e[?1049h` (alt-screen) / CR
  # (rewind spoof) / BEL would otherwise reach the TTY and EXECUTE. Mirrors the
  # MenuView (#563) and tool-tail/approval-card CWE-150 sink tests.
  describe "terminal-escape injection (CWE-150, #564)" do
    # The full exploit chain a malicious tool-arg filename / name / question
    # carries: clear-screen, OSC title-set (BEL-terminated), alt-screen-enter,
    # CR (line-rewind spoof), bare BEL.
    let(:evil) { "read \e[2J\e]0;PWNED\a\e[?1049h\rrest\a.txt" }

    # No raw control byte that can repaint, move the cursor, set the title, or
    # rewind the line may survive to the terminal.
    matcher :have_no_raw_escapes do
      match { |str| ["\e", "\a", "\r", "\e]"].none? { |seq| str.include?(seq) } }
      failure_message { |str| "expected no raw escapes, got #{str.inspect}" }
    end

    it "neutralizes escapes in a RUNNING card's last_activity" do
      line = cards.card_lines([entry(last_activity: evil)]).join("\n")
      expect(line).to have_no_raw_escapes
      expect(line).to include("^[") # ESC shown as visible caret notation
    end

    it "neutralizes escapes in a RUNNING card's subagent name" do
      line = cards.card_lines([entry(subagent: "ex\e[2J\aplore")]).join("\n")
      expect(line).to have_no_raw_escapes
    end

    it "neutralizes escapes in a BLOCKED card's ask_question" do
      e = entry(status: :blocked_on_human, ask_question: evil)
      expect(cards.card_lines([e]).join("\n")).to have_no_raw_escapes
    end

    it "neutralizes escapes in a BLOCKED card's subagent name" do
      e = entry(status: :blocked_on_human, subagent: "ex\e]0;X\aplore", ask_question: "q")
      expect(cards.card_lines([e]).join("\n")).to have_no_raw_escapes
    end

    it "neutralizes escapes in an APPROVAL card's approval_command" do
      e = entry(status: :needs_approval, approval_command: evil)
      expect(cards.card_lines([e]).join("\n")).to have_no_raw_escapes
    end

    it "neutralizes escapes in an APPROVAL card's approval_question fallback" do
      e = entry(status: :needs_approval, approval_command: "", approval_question: evil)
      expect(cards.card_lines([e]).join("\n")).to have_no_raw_escapes
    end

    it "preserves rubino's OWN SGR colour on a legit card (not stripped)" do
      colored = described_class.new(pastel: Pastel.new(enabled: true))
      line = colored.card_lines([entry(last_activity: "read lib/app.rb")]).join("\n")
      # the cyan glyph wrapper survives…
      expect(line).to include("\e[36m")
      # …and the legible activity text is intact.
      expect(line.gsub(/\e\[[0-9;]*m/, "")).to include("read lib/app.rb")
    end
  end
end
