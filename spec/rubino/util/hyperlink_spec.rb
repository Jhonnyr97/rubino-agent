# frozen_string_literal: true

RSpec.describe Rubino::Util::Hyperlink do
  # Support is memoized per process; every example here flips env vars,
  # so reset before each so the new env is read fresh.
  before do
    described_class.reset!
    ENV.delete("RUBINO_HYPERLINKS")
    ENV.delete("NO_COLOR")
    ENV.delete("TERM_PROGRAM")
    ENV.delete("TERM")
  end

  after { described_class.reset! }

  describe ".supported?" do
    it "is true on known-good TERM_PROGRAM (iTerm.app)" do
      ENV["TERM_PROGRAM"] = "iTerm.app"
      expect(described_class.supported?).to be true
    end

    it "is true on WezTerm" do
      ENV["TERM_PROGRAM"] = "WezTerm"
      expect(described_class.supported?).to be true
    end

    it "is true on kitty (detected via TERM, not TERM_PROGRAM)" do
      ENV["TERM"] = "xterm-kitty"
      expect(described_class.supported?).to be true
    end

    it "is false on Apple_Terminal (does not support OSC 8)" do
      ENV["TERM_PROGRAM"] = "Apple_Terminal"
      expect(described_class.supported?).to be false
    end

    it "defaults to false on unknown terminals" do
      ENV["TERM_PROGRAM"] = "weird-term-3000"
      expect(described_class.supported?).to be false
    end

    it "defaults to false when nothing is set" do
      expect(described_class.supported?).to be false
    end

    it "is forced on by RUBINO_HYPERLINKS=1 even on Apple_Terminal" do
      ENV["TERM_PROGRAM"] = "Apple_Terminal"
      ENV["RUBINO_HYPERLINKS"] = "1"
      expect(described_class.supported?).to be true
    end

    it "is forced off by RUBINO_HYPERLINKS=0 even on iTerm" do
      ENV["TERM_PROGRAM"] = "iTerm.app"
      ENV["RUBINO_HYPERLINKS"] = "0"
      expect(described_class.supported?).to be false
    end

    it "is forced off by NO_COLOR" do
      ENV["TERM_PROGRAM"] = "iTerm.app"
      ENV["NO_COLOR"] = "1"
      expect(described_class.supported?).to be false
    end
  end

  describe ".wrap" do
    it "returns the label unchanged when not supported" do
      expect(described_class.wrap("foo", uri: "file:///x")).to eq("foo")
    end

    it "wraps the label in OSC 8 when supported" do
      ENV["RUBINO_HYPERLINKS"] = "1"
      out = described_class.wrap("README.md", uri: "file:///abs/README.md")
      expect(out).to eq("\e]8;;file:///abs/README.md\e\\README.md\e]8;;\e\\")
    end

    it "returns label even when supported if URI is nil or empty" do
      ENV["RUBINO_HYPERLINKS"] = "1"
      expect(described_class.wrap("x", uri: nil)).to eq("x")
      expect(described_class.wrap("x", uri: "")).to eq("x")
    end
  end

  describe ".file_uri" do
    it "returns nil for a missing path" do
      expect(described_class.file_uri("/does/not/exist/abc")).to be_nil
    end

    it "returns nil for empty/nil input" do
      expect(described_class.file_uri(nil)).to be_nil
      expect(described_class.file_uri("")).to be_nil
    end

    it "builds file:// from an absolute existing path" do
      expect(described_class.file_uri(__FILE__)).to eq("file://#{__FILE__}")
    end

    it "expands relative paths to absolute before building file://" do
      Dir.chdir(File.dirname(__FILE__)) do
        rel = File.basename(__FILE__)
        expect(described_class.file_uri(rel)).to eq("file://#{File.expand_path(rel)}")
      end
    end
  end

  # Regression: OSC 8 escape sequences must NEVER reach the API adapter.
  # The HTTP boundary serialises events to JSON and sends them to the web UI,
  # which renders its own `<a>` elements from the structured `arguments`
  # field. A leaked `\e]8;;...\e\\` in a JSON payload would show as literal
  # garbage in the web client. The CLI adapter is the only place that calls
  # Hyperlink.wrap_path; this test pins the API path stays clean even when
  # the env says hyperlinks are on.
  describe "isolation from API adapter" do
    it "does not appear in tool_started events emitted by the API adapter" do
      ENV["RUBINO_HYPERLINKS"] = "1"
      described_class.reset!

      api = Rubino::UI::API.new
      api.tool_started("read", arguments: { "file_path" => __FILE__ })
      event = api.events.last

      expect(event[:type]).to eq(:tool_started)
      expect(event[:payload]).to eq(name: "read", arguments: { "file_path" => __FILE__ }, at: nil)
      # Round-trip through JSON to mimic the SSE encoding — any leaked
      # escape would either explode here or surface in the string.
      serialized = JSON.dump(event)
      expect(serialized).not_to include("\\u001b]8")
      expect(serialized).not_to include("\e]8")
    end
  end

  describe ".wrap_path" do
    it "wraps with file:// URI when path exists and terminal supports" do
      ENV["RUBINO_HYPERLINKS"] = "1"
      out = described_class.wrap_path(__FILE__)
      expect(out).to include("\e]8;;file://#{__FILE__}\e\\")
      expect(out).to end_with("\e]8;;\e\\")
    end

    it "honors a custom label different from the path" do
      ENV["RUBINO_HYPERLINKS"] = "1"
      out = described_class.wrap_path(__FILE__, label: "spec")
      expect(out).to include("\e\\spec\e]8;;")
    end

    it "returns the label (or path) unchanged when file does not exist" do
      ENV["RUBINO_HYPERLINKS"] = "1"
      expect(described_class.wrap_path("/no/such/path")).to eq("/no/such/path")
    end

    it "returns plain text when terminal does not support OSC 8" do
      expect(described_class.wrap_path(__FILE__)).to eq(__FILE__)
    end
  end
end
