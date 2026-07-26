# frozen_string_literal: true

require "tmpdir"

# `formatters:` config wired into EditTool (see lib/rubino/formatters.rb),
# covering both the single old_string/new_string form and the `edits` array
# form. Uses a real standalone shell command (no ruby/bundler subprocess —
# that would inherit THIS process's bundler env and try to touch the gem's
# own Gemfile.lock) so the sandboxed spawn actually reformats a real file.
RSpec.describe Rubino::Tools::EditTool do
  # NB: the tmp_dir prefix deliberately avoids the substring "formatter" so a
  # `not_to include("[formatter]")` assertion can't accidentally match the
  # tmp path embedded in an unrelated message.
  let(:upcase_in_place) do
    %(bash -c 'tr "[:lower:]" "[:upper:]" < "$1" > "$1.formatted" && mv "$1.formatted" "$1"' _)
  end
  let(:tmp_dir) { Dir.mktmpdir("edit_tool_fmt_spec") }

  before { Rubino.configuration.set("terminal", "cwd", tmp_dir) }

  after do
    Rubino.configuration.set("terminal", "cwd", nil)
    Rubino.configuration.set("formatters", {})
    FileUtils.rm_rf(tmp_dir)
  end

  def write_file(name, content)
    path = File.join(tmp_dir, name)
    File.write(path, content)
    path
  end

  def payload(result) = result.is_a?(Hash) ? result[:output] : result

  describe "single old_string/new_string form" do
    subject(:tool) { described_class.new }

    describe "no formatters configured (unaffected, today's behavior)" do
      it "applies the edit untouched" do
        path = write_file("a.rb", "hello")
        result = tool.call("file_path" => path, "old_string" => "hello", "new_string" => "hi")
        expect(File.read(path)).to eq("hi")
        expect(result[:output]).not_to include("[formatter]")
      end
    end

    describe "a matching formatter" do
      before { Rubino.configuration.set("formatters", { "*.up" => upcase_in_place }) }

      it "runs after the edit and the real on-disk content reflects it" do
        path = write_file("a.up", "hello world")
        tool.call("file_path" => path, "old_string" => "world", "new_string" => "ruby")
        expect(File.read(path)).to eq("HELLO RUBY")
      end

      it "appends a note to the tool output without failing the edit" do
        path   = write_file("a.up", "hello world")
        result = tool.call("file_path" => path, "old_string" => "world", "new_string" => "ruby")
        expect(result[:output]).to include("Edit applied")
        expect(result[:output]).to include("[formatter]")
        expect(result[:output]).to include("reformatted")
      end

      it "refreshes the read-tracker with the REAL final bytes so a follow-up edit isn't refused" do
        tracker = Rubino::Tools::ReadTracker.new
        tool.read_tracker = tracker
        path = write_file("a.up", "hello world")
        tracker.register(path, File.mtime(path), nil)

        tool.call("file_path" => path, "old_string" => "world", "new_string" => "ruby")

        # If the tracker still held the PRE-formatter bytes ("hello ruby"),
        # this second edit would fail the stale-read gate against the
        # ACTUAL on-disk content ("HELLO RUBY").
        result = tool.call("file_path" => path, "old_string" => "HELLO", "new_string" => "HI")
        expect(payload(result)).to include("Edit applied")
        expect(File.read(path)).to eq("HI RUBY")
      end
    end

    describe "a non-matching file" do
      before { Rubino.configuration.set("formatters", { "*.up" => upcase_in_place }) }

      it "is left completely untouched" do
        path   = write_file("a.txt", "hello world")
        result = tool.call("file_path" => path, "old_string" => "world", "new_string" => "ruby")
        expect(File.read(path)).to eq("hello ruby")
        expect(result[:output]).not_to include("[formatter]")
      end
    end

    describe "a failing formatter" do
      before { Rubino.configuration.set("formatters", { "*.up" => "false" }) }

      it "does not fail the edit — the change is still applied and the call succeeds" do
        path   = write_file("a.up", "hello world")
        result = tool.call("file_path" => path, "old_string" => "world", "new_string" => "ruby")

        expect(File.read(path)).to eq("hello ruby")
        expect(result[:output]).to include("Edit applied")
        expect(result[:output]).to include("[formatter]")
        expect(result[:output]).to include("exited 1")
      end
    end
  end

  describe "edits array form" do
    subject(:tool) { described_class.new }

    describe "a matching formatter" do
      before { Rubino.configuration.set("formatters", { "*.up" => upcase_in_place }) }

      it "runs after the batch of edits and the real on-disk content reflects it" do
        path = write_file("a.up", "a=1\nb=2\n")
        result = tool.call(
          "file_path" => path,
          "edits" => [{ "old_string" => "a=1", "new_string" => "a=9" }]
        )
        expect(File.read(path)).to eq("A=9\nB=2\n")
        expect(result[:output]).to include("[formatter]")
      end
    end

    describe "a failing formatter" do
      before { Rubino.configuration.set("formatters", { "*.up" => "false" }) }

      it "does not fail the batch edit — the change is still applied" do
        path = write_file("a.up", "A=1\nB=2\n")
        result = tool.call(
          "file_path" => path,
          "edits" => [{ "old_string" => "A=1", "new_string" => "A=9" }]
        )
        expect(File.read(path)).to eq("A=9\nB=2\n")
        expect(result[:output]).to include("Applied")
        expect(result[:output]).to include("[formatter]")
        expect(result[:output]).to include("exited 1")
      end
    end
  end
end
