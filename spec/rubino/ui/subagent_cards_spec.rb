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

  # R1 — the footer card stack must show EVERY child the registry still counts
  # as alive (BackgroundTasks::LIVE_STATUSES), not a narrower hand-maintained
  # subset. A child parked on :blocked_on_parent (asking its agent-parent) still
  # holds a slot and ticks; dropping it here vanished a live sibling from the
  # footer while the switcher/picker still listed it.
  describe "footer liveness matches the registry oracle (R1)" do
    it "renders a card for a child still RUNNING" do
      line = plain(cards.card_lines([entry(id: "sa_run", status: :running)])).first
      expect(line).to include("sa_run")
    end

    it "renders a card for a child parked on needs_approval" do
      e = entry(id: "sa_apr", status: :needs_approval, approval_command: "rm -rf build")
      line = plain(cards.card_lines([e])).first
      expect(line).to include("sa_apr")
      expect(line).to include("needs approval")
    end

    it "renders a card for a child parked on blocked_on_parent (previously dropped)" do
      e = entry(id: "sa_bop", status: :blocked_on_parent)
      line = plain(cards.card_lines([e])).first
      expect(line).to include("sa_bop")
    end

    it "shows ALL live siblings together — running + needs_approval + blocked_on_parent" do
      es = [
        entry(id: "sa_run", status: :running),
        entry(id: "sa_apr", status: :needs_approval, approval_command: "echo hi"),
        entry(id: "sa_bop", status: :blocked_on_parent)
      ]
      joined = plain(cards.card_lines(es)).join("\n")
      expect(joined).to include("sa_run").and include("sa_apr").and include("sa_bop")
    end

    it "filters by exactly BackgroundTasks::LIVE_STATUSES (no drift)" do
      Rubino::Tools::BackgroundTasks::LIVE_STATUSES.each do |st|
        line = plain(cards.card_lines([entry(id: "sa_#{st}", status: st)])).first
        expect(line).to include("sa_#{st}"), "expected #{st} to be shown on the footer"
      end
      # ...and a terminal status is NOT shown.
      expect(cards.card_lines([entry(status: :failed)])).to eq([])
    end
  end

  it "renders one COMPACT collapsed card row per running subagent (no noisy activity tail)" do
    e = entry(id: "sa_9ae4", tool_count: 14, last_activity: 'grep "def authenticate"',
              started_at: Time.now - 38)
    line = plain(cards.card_lines([e])).first
    expect(line).to include("▸ sa_9ae4 · explore · running · 14 tools")
    # The per-tool activity (long grep/glob args / paths) is intentionally NOT on
    # the always-visible card — it lives in the agent's own view / drill-in.
    expect(line).not_to include("grep")
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

  it "keeps concurrent tasks distinguishable by id (#127)" do
    a = entry(id: "sa_a", subagent: "explore", last_activity: "read lib/auth/session.rb")
    b = entry(id: "sa_b", subagent: "build", last_activity: 'shell "bundle exec rspec"')
    lines = plain(cards.card_lines([a, b]))
    # Distinguished by id + name on the compact card (the activity is off-card).
    expect(lines[0]).to include("sa_a · explore")
    expect(lines[1]).to include("sa_b · build")
  end

  # S7 Y1 — three subagents spawned at once all show the same agent TYPE
  # ("general"), so a dev can't tell them apart except by sa_id. Surface a
  # descriptive DIMENSION drawn from the task prompt on the card instead.
  describe "card label prefers the task dimension over the bare agent type (Y1)" do
    it "uses a **BOLD** dimension heading from the prompt" do
      es = [
        entry(id: "sa_a", subagent: "general",
              prompt: "You are the **BUG AUDIT** reviewer for the shop/ module…"),
        entry(id: "sa_b", subagent: "general",
              prompt: "You are the **STRUCTURE** reviewer for the shop/ module…"),
        entry(id: "sa_c", subagent: "general",
              prompt: "You are the **TEST COVERAGE** reviewer for the shop/ module…")
      ]
      lines = plain(cards.card_lines(es))
      expect(lines[0]).to include("sa_a · BUG AUDIT · running")
      expect(lines[1]).to include("sa_b · STRUCTURE · running")
      expect(lines[2]).to include("sa_c · TEST COVERAGE · running")
      # The bare type no longer makes the three cards indistinguishable.
      expect(lines[0]).not_to include("· general ·")
    end

    it "falls back to the prompt's first line when there is no bold heading" do
      e = entry(id: "sa_p", subagent: "general", prompt: "Migrate the billing tests to RSpec")
      line = plain(cards.card_lines([e])).first
      expect(line).to include("sa_p · Migrate the billing tests to RSpec · running")
    end

    it "falls back to the agent TYPE when the prompt is blank" do
      e = entry(id: "sa_t", subagent: "explore", prompt: "")
      line = plain(cards.card_lines([e])).first
      expect(line).to include("sa_t · explore · running")
    end

    it "applies the dimension label to a needs_approval card too" do
      e = entry(id: "sa_x", status: :needs_approval, subagent: "general",
                prompt: "You are the **DEPLOY** agent", approval_command: "rm -rf build")
      line = plain(cards.card_lines([e])).first
      expect(line).to include("sa_x · DEPLOY · needs approval: rm -rf build")
    end
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

    # FINDING #55: the cancel hint must teach the real slash command (/stop <id>,
    # alias of /agents <id> --stop), NOT a bare `--stop` — typed at the main
    # prompt a bare `--stop` is not a command and becomes a model-interpreted
    # message rather than cancelling the sub.
    it "teaches the /stop <id> command to cancel, not a bare --stop" do
      hint = plain(cards.card_lines([entry])).last
      expect(hint).to include("/stop <id> to cancel")
      expect(hint).not_to match(%r{(?<!/agents <id> )--stop})
    end

    it "teaches the /stop <id> command on the approval-pending hint too" do
      e = entry(id: "sa_x", status: :needs_approval, approval_command: "c")
      hint = plain(cards.card_lines([e])).last
      expect(hint).to include("/stop <id> to cancel")
      expect(hint).not_to match(%r{(?<!/agents <id> )--stop})
    end

    # Concurrent approval toasts: several children parked on approval at once must
    # render as a CALM, left-aligned, single-line stack — a consistent left margin
    # and a bounded right edge, never one row wrapping mid-word onto a second
    # physical line at a stray column. Each card row is clamped to the same
    # display-column budget and elided on a glyph boundary (trailing "…"), so a
    # long (model-chosen) approval command can't blow a row past the budget.
    it "lays concurrent needs_approval rows at a consistent left margin within the width budget" do
      long = "rm -rf /very/long/build/output/directory/that/keeps/going/and/going/and/going"
      es = [
        entry(id: "sa_f831b59a", subagent: "general", status: :needs_approval, approval_command: long),
        entry(id: "sa_aa11bb22", subagent: "explore", status: :needs_approval, approval_command: long)
      ]
      rows = plain(cards.card_lines(es)).first(2)

      width = Rubino::UI::SubagentCards::DEFAULT_CARD_WIDTH
      rows.each do |row|
        # Consistent LEFT margin: every card row starts at the same two-space indent.
        expect(row).to start_with("  ●")
        # Bounded RIGHT edge: no row exceeds the budget, so it can't wrap to a
        # second physical line at a stray offset.
        expect(Rubino::UI::LiveRegion.display_width(row)).to be <= width
      end
    end

    # A row clamped to the budget must cut on a glyph boundary and signal the
    # elision with a trailing "…" — never split a word across two physical lines.
    it "elides an over-long approval row with a trailing … instead of wrapping mid-word" do
      long = "fibonacci_with_a_really_long_unbroken_token_that_overflows_the_card_width_budget_#{"x" * 40}"
      e = entry(id: "sa_f831b59a", subagent: "general", status: :needs_approval, approval_command: long)
      row = plain(cards.card_lines([e])).first
      width = Rubino::UI::SubagentCards::DEFAULT_CARD_WIDTH
      expect(Rubino::UI::LiveRegion.display_width(row)).to be <= width
      expect(row).to end_with("…")
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

    # NOTE: last_activity is no longer rendered on the compact card (it moved to
    # the agent view / drill-in), so the card-side last_activity escape sink is
    # gone. The subagent NAME (still on the card) keeps its CWE-150 guard below.
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
      line = colored.card_lines([entry(id: "sa_z", subagent: "explore")]).join("\n")
      # the cyan glyph wrapper survives…
      expect(line).to include("\e[36m")
      # …and the legible compact card text is intact.
      expect(line.gsub(/\e\[[0-9;]*m/, "")).to include("sa_z · explore · running")
    end
  end
end
