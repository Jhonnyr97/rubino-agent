# frozen_string_literal: true

# `mode_changed` is the UI signal emitted whenever Modes.set runs (via
# `/mode plan`, `--yolo`, or an API caller). Every adapter implements it,
# so this spec pins all three at once: the CLI free-line vocabulary, the
# Null recording shape (used by tests + replay), and the API event payload
# (used by the web UI to update its own mode chip).
RSpec.describe "UI#mode_changed" do
  def capture_stdout
    old = $stdout
    $stdout = StringIO.new
    yield
    $stdout.string
  ensure
    $stdout = old
  end

  describe Rubino::UI::CLI do
    subject(:ui) { described_class.new }

    it "renders a `┄ mode <prev> → <new> ┄` free line (compact, no timestamp)" do
      out = capture_stdout { ui.mode_changed(:plan, previous: :default) }
      expect(out).to match(/┄ mode default → plan ┄/)
    end

    it "omits the arrow when there is no previous (initial set)" do
      out = capture_stdout { ui.mode_changed(:plan) }
      expect(out).to match(/┄ mode plan ┄/)
      expect(out).not_to match(/→/)
    end

    it "colours the line yellow when entering yolo so it stands out scrolling back" do
      # Pastel auto-disables ANSI on non-TTY (StringIO). Force-enable here to
      # actually see the escape sequence we care about.
      ui.instance_variable_set(:@pastel, Pastel.new(enabled: true))
      out = capture_stdout { ui.mode_changed(:yolo, previous: :default) }
      yellow = Pastel.new(enabled: true).yellow("placeholder")
      yellow_prefix = yellow[0, yellow.index("placeholder")]
      expect(out).to include(yellow_prefix)
    end
  end

  describe Rubino::UI::Null do
    subject(:ui) { described_class.new }

    it "records mode + previous in the message tape" do
      ui.mode_changed(:yolo, previous: :default)
      expect(ui.messages.last).to eq(level: :mode_changed, message: :yolo, previous: :default)
    end
  end

  describe Rubino::UI::API do
    subject(:ui) { described_class.new }

    it "emits a `:mode_changed` event the orchestrator can forward over SSE" do
      ui.mode_changed(:plan, previous: :default)
      event = ui.events.last
      expect(event[:type]).to eq(:mode_changed)
      expect(event[:payload]).to eq(mode: :plan, previous: :default)
    end

    it "survives a JSON round-trip (the HTTP boundary serialises events)" do
      ui.mode_changed(:yolo, previous: :plan)
      serialised = JSON.dump(ui.events.last)
      decoded = JSON.parse(serialised)
      expect(decoded["type"]).to eq("mode_changed")
      expect(decoded["payload"]).to eq("mode" => "yolo", "previous" => "plan")
    end
  end
end