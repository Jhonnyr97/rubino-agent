# frozen_string_literal: true

require "stringio"

# UI::SubagentView renders a running subagent's TOOL ACTIVITY as compact,
# indented, per-subagent-colored rows. It is DISPLAY-ONLY: it writes to its
# injected IO (the composer proxy in the live CLI) and never feeds the parent
# loop's messages or recorder. These specs capture the IO and assert the
# rendered surface, the suppressions, the safe confirm, and the deterministic
# per-name color.
RSpec.describe Rubino::UI::SubagentView do
  subject(:ui)  { described_class.new(agent_name: "explore", out: io) }

  let(:io)      { StringIO.new }

  # Pastel honors NO_COLOR / non-tty, but be explicit: strip ANSI so the
  # assertions check the text, and check color separately via #color.
  def plain(text)
    text.gsub(/\e\[[0-9;]*m/, "")
  end

  describe "tool activity rendering" do
    it "renders tool_started as an indented, name-prefixed row" do
      ui.tool_started("read", arguments: { "file_path" => "lib/foo.rb" })
      expect(plain(io.string)).to eq("    ⟂ explore · read lib/foo.rb\n")
    end

    it "renders tool_started with no hint when arguments are bare" do
      ui.tool_started("think")
      expect(plain(io.string)).to eq("    ⟂ explore · think\n")
    end

    it "renders tool_finished with the success icon and metric" do
      result = Rubino::Tools::Result.success(
        name: "grep", call_id: "1", output: "3 matches", metrics: "3 matches"
      )
      ui.tool_finished("grep", result: result)
      expect(plain(io.string)).to eq("    ⟂ explore · ✓ grep · 3 matches\n")
    end

    it "renders tool_finished with the failure icon" do
      result = Rubino::Tools::Result.error(name: "grep", call_id: "1", error: "boom")
      ui.tool_finished("grep", result: result)
      expect(plain(io.string)).to start_with("    ⟂ explore · ✗ grep")
    end

    it "colors the row in the subagent's color" do
      pastel = Pastel.new(enabled: true)
      view = described_class.new(agent_name: "explore", out: io, pastel: pastel)
      view.tool_started("read", arguments: { "path" => "x" })
      expected = pastel.public_send(view.color, "    ⟂ explore · read x")
      expect(io.string).to include(expected)
    end
  end

  describe "suppressed noise" do
    it "suppresses token stream chunks" do
      ui.stream(type: :content, text: "some prose", message_id: 0)
      ui.stream_end
      expect(io.string).to eq("")
    end

    it "suppresses the final assistant text (parent prints the result)" do
      ui.assistant_text("the subagent's prose answer")
      expect(io.string).to eq("")
    end

    it "suppresses thinking and body" do
      ui.thinking_started
      ui.body("raw body")
      expect(io.string).to eq("")
    end
  end

  describe "low-noise annotations" do
    it "renders note as a dim nested row" do
      ui.note("turn · 2s · 1 tool")
      expect(plain(io.string)).to eq("    ⟂ explore · turn · 2s · 1 tool\n")
    end
  end

  describe "#confirm" do
    it "auto-denies without prompting (never blocks mid-delegation)" do
      expect(ui.confirm("rm -rf /?", scope: "shell:rm")).to be(false)
    end

    it "accepts the scope: keyword like every adapter" do
      expect { ui.confirm("q", scope: "x") }.not_to raise_error
    end
  end

  describe "deterministic per-subagent color" do
    it "maps the same name to the same color" do
      a = described_class.new(agent_name: "explore", out: io).color
      b = described_class.new(agent_name: "explore", out: io).color
      expect(a).to eq(b)
    end

    it "picks a color from the palette" do
      expect(described_class::PALETTE).to include(ui.color)
    end

    it "is stable across processes (CRC32, not String#hash)" do
      # CRC32("explore") % 6 — recompute independently of the instance.
      expected = described_class::PALETTE[Zlib.crc32("explore") % described_class::PALETTE.size]
      expect(ui.color).to eq(expected)
    end
  end

  describe "collapsed-card mode (Variant A, #124)" do
    subject(:card_view) do
      described_class.new(agent_name: "explore", out: io, entry_id: entry.id, parent_ui: parent)
    end

    before do
      allow(parent).to receive(:set_subagent_cards) { repaints << :paint }
    end

    let(:registry) { Rubino::Tools::BackgroundTasks.instance }
    let(:entry)    { registry.reserve(subagent: "explore", prompt: "find the bug") }

    # A card-mode view: wired with an entry id + a parent UI whose card repaint
    # we record, so we can assert it feeds the registry and does NOT flood $stdout.
    let(:repaints) { [] }
    let(:parent)   { double("parent_ui", set_subagent_cards: nil) }

    it "feeds tool_started to the registry instead of flooding stdout (#124)" do
      card_view.tool_started("read", arguments: { "file_path" => "lib/foo.rb" })
      reread = registry.find(entry.id)
      expect(reread.tool_count).to eq(1)
      expect(reread.last_activity).to eq("read lib/foo.rb")
      # No per-tool row was written to the parent terminal.
      expect(io.string).to eq("")
      expect(repaints).not_to be_empty
    end

    it "appends finish lines to the registry recent-ring (the drill-in tail, #71)" do
      result = Rubino::Tools::Result.success(name: "grep", call_id: "1", output: "3 matches", metrics: "3 matches")
      card_view.tool_finished("grep", result: result)
      expect(registry.find(entry.id).activity_log.last).to include("✓ grep · 3 matches")
      expect(io.string).to eq("")
    end

    it "folds note/status/info away in card mode (no nested rows)" do
      card_view.note("turn · 2s")
      card_view.status("x")
      card_view.info("y")
      expect(io.string).to eq("")
    end

    it "reports card_mode? true only when wired with an entry id" do
      expect(card_view.card_mode?).to be(true)
      expect(described_class.new(agent_name: "explore", out: io).card_mode?).to be(false)
    end
  end

  describe "#confirm with an approval handler (Option 2)" do
    it "delegates to the handler and returns its decision instead of auto-denying" do
      handler = ->(_q, scope: nil, **_ctx) { true }
      view = described_class.new(agent_name: "explore", out: io, entry_id: "sa_1", approve: handler)
      expect(view.confirm("Allow shell?", scope: "shell:ls")).to be(true)
    end

    it "still auto-denies when no handler is wired (legacy/foreground)" do
      expect(ui.confirm("rm -rf /?", scope: "shell:rm")).to be(false)
    end
  end

  describe "UI surface coverage" do
    # The child Agent loop / lifecycle / tool executor call a known set of UI
    # methods. SubagentView must respond to every one in the UI::Base contract
    # (the authoritative interface every adapter implements) plus the extra
    # loop-called methods the executor probes (tool_chunk) — so the nested run
    # never hits a NoMethodError.
    surface = Rubino::UI::Base.instance_methods(false) + %i[tool_chunk]

    surface.uniq.each do |method_name|
      it "responds to ##{method_name}" do
        expect(ui).to respond_to(method_name)
      end
    end
  end
end
