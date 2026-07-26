# frozen_string_literal: true

require "tmpdir"

# `formatters:` config wired into WriteTool (see lib/rubino/formatters.rb).
# Uses a real standalone shell command (no ruby/bundler subprocess — that
# would inherit THIS process's bundler env and try to touch the gem's own
# Gemfile.lock) so the sandboxed spawn actually reformats a real file.
RSpec.describe Rubino::Tools::WriteTool do
  subject(:tool) { described_class.new }

  # NB: the tmp_dir prefix deliberately avoids the substring "formatter" —
  # WriteTool's own success message embeds the full file path ("created
  # <path> (N bytes)"), so a prefix like "write_tool_formatters_spec" would
  # make `include("formatter")` assertions pass for the wrong reason. Assert
  # on the precise "[formatter]" tag Formatters.note_for emits instead.
  let(:upcase_in_place) do
    %(bash -c 'tr "[:lower:]" "[:upper:]" < "$1" > "$1.formatted" && mv "$1.formatted" "$1"' _)
  end
  let(:tmp_dir) { Dir.mktmpdir("write_tool_fmt_spec") }

  before { Rubino.configuration.set("terminal", "cwd", tmp_dir) }

  after do
    Rubino.configuration.set("terminal", "cwd", nil)
    Rubino.configuration.set("formatters", {})
    FileUtils.rm_rf(tmp_dir)
  end

  describe "no formatters configured (unaffected, today's behavior)" do
    it "writes the file untouched" do
      path = File.join(tmp_dir, "a.rb")
      result = tool.call("file_path" => path, "content" => "hello")
      expect(File.read(path)).to eq("hello")
      expect(result[:output]).not_to include("[formatter]")
    end
  end

  describe "a matching formatter" do
    before { Rubino.configuration.set("formatters", { "*.up" => upcase_in_place }) }

    it "runs after the write and the real on-disk content reflects it" do
      path = File.join(tmp_dir, "a.up")
      tool.call("file_path" => path, "content" => "hello world")
      expect(File.read(path)).to eq("HELLO WORLD")
    end

    it "reports the byte/line metrics and preview body from the FORMATTED content" do
      path   = File.join(tmp_dir, "a.up")
      result = tool.call("file_path" => path, "content" => "hello\nworld\n")

      expect(result[:metrics]).to eq("2 lines · 12B") # unchanged length, just cased
      expect(result[:body]).to eq("HELLO\nWORLD")
    end

    it "appends a note to the tool output" do
      path   = File.join(tmp_dir, "a.up")
      result = tool.call("file_path" => path, "content" => "hello")
      expect(result[:output]).to include("created #{path}")
      expect(result[:output]).to include("[formatter]")
      expect(result[:output]).to include("reformatted")
    end

    it "refreshes the read-tracker with the REAL final bytes so a follow-up edit isn't refused" do
      tracker = Rubino::Tools::ReadTracker.new
      tool.read_tracker = tracker
      path = File.join(tmp_dir, "a.up")

      tool.call("file_path" => path, "content" => "hello world")

      edit = Rubino::Tools::EditTool.new
      edit.read_tracker = tracker
      # If the tracker still held the PRE-formatter bytes ("hello world"), this
      # would fail the read-gate/exact-match against the actual on-disk
      # ("HELLO WORLD"). It must succeed because run_formatters! re-registered
      # the post-formatter bytes.
      result = edit.call("file_path" => path, "old_string" => "HELLO", "new_string" => "HI")
      expect(payload(result)).to include("Edit applied")
      expect(File.read(path)).to eq("HI WORLD")
    end
  end

  describe "a non-matching file" do
    before { Rubino.configuration.set("formatters", { "*.up" => upcase_in_place }) }

    it "is left completely untouched" do
      path   = File.join(tmp_dir, "a.txt")
      result = tool.call("file_path" => path, "content" => "hello world")
      expect(File.read(path)).to eq("hello world")
      expect(result[:output]).not_to include("[formatter]")
    end
  end

  describe "a failing formatter" do
    before { Rubino.configuration.set("formatters", { "*.up" => "false" }) }

    it "does not fail the write — the file is still written and the call succeeds" do
      path   = File.join(tmp_dir, "a.up")
      result = tool.call("file_path" => path, "content" => "hello world")

      expect(File.read(path)).to eq("hello world")
      expect(result[:output]).to include("created")
      expect(result[:output]).to include("[formatter]")
      expect(result[:output]).to include("exited 1")
    end
  end

  def payload(result) = result.is_a?(Hash) ? result[:output] : result
end
