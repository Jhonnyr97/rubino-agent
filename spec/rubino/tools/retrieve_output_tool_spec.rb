# frozen_string_literal: true

require "spec_helper"
require "fileutils"
require "tmpdir"

RSpec.describe Rubino::Tools::RetrieveOutputTool do
  subject(:tool) { described_class.new }

  let(:home) { Dir.mktmpdir("retrieve_home") }
  let(:results_dir) { File.join(home, "tool-results") }

  before do
    allow(Rubino).to receive(:home_path).and_return(home)
    FileUtils.mkdir_p(results_dir)
  end

  after { FileUtils.rm_rf(home) }

  def spill(id, content)
    File.write(File.join(results_dir, "#{id}.txt"), content)
  end

  it "is gated on the tool_output_compression config key" do
    expect(tool.config_key).to eq("tool_output_compression")
  end

  it "is low risk and read-only" do
    expect(tool.risk_level).to eq(:low)
    expect(tool.risky?).to be(false)
  end

  describe "#call" do
    it "round-trips: retrieves the full spilled output by id" do
      full = (1..200).map { |i| "line #{i}" }.join("\n")
      spill("call_42", full)

      expect(tool.call("id" => "call_42")).to eq(full)
    end

    it "round-trips a sanitized id the SAME way spill_full_output sanitizes call_id" do
      # ToolExecutor#spill_full_output writes to <sanitized call_id>.txt, where
      # sanitize = gsub(/[^a-zA-Z0-9_.-]/, "_"). A pointer prints the sanitized
      # id, so the tool must sanitize identically to find the file.
      spill("call_a_b", "recovered body")

      expect(tool.call("id" => "call/a b")).to eq("recovered body")
    end

    it "returns a clear message for an unknown id" do
      expect(tool.call("id" => "nope")).to eq("No stored output for id=nope (it may have expired).")
    end

    it "requires an id" do
      expect(tool.call({})).to include("missing keyword")
    end

    it "cannot traverse out of the tool-results dir (path traversal is sanitized away)" do
      # A secret outside tool-results …
      secret = File.join(home, "secret.txt")
      File.write(secret, "TOP SECRET")
      # … an id trying to traverse to it sanitizes to underscores, so it maps to
      # a harmless in-dir filename that doesn't exist — never the secret.
      result = tool.call("id" => "../secret")

      expect(result).not_to include("TOP SECRET")
      expect(result).to start_with("No stored output for id=")
      # the `/` collapsed to `_`, so the lookup stays inside tool-results/
      # (.._secret.txt) and never escapes to the sibling secret file.
      expect(result).to include(".._secret")
    end

    it "treats an absolute-path id as an in-dir filename, never the real path" do
      File.write("/tmp/retrieve_abs_secret.txt", "ABS SECRET") unless File.exist?("/tmp/retrieve_abs_secret.txt")
      result = tool.call("id" => "/tmp/retrieve_abs_secret")
      expect(result).not_to include("ABS SECRET")
      expect(result).to start_with("No stored output for id=")
    ensure
      FileUtils.rm_f("/tmp/retrieve_abs_secret.txt")
    end

    it "accepts the symbol :id form too" do
      spill("sym", "via symbol")
      expect(tool.call(id: "sym")).to eq("via symbol")
    end
  end
end
