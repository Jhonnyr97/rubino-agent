# frozen_string_literal: true

require "timeout"

# Tests covering the specific bugs found and fixed in each tool.

# ---------------------------------------------------------------------------
# Registry — tool_enabled_in_config? passes config_key, not nil
# ---------------------------------------------------------------------------
RSpec.describe Rubino::Tools::Registry do
  describe ".enabled_tools" do
    it "returns tools when the config enables them" do
      described_class.register(Rubino::Tools::GlobTool.new)
      # Default config has tools.filesystem: true etc.; glob maps to "glob"
      tools = described_class.enabled_tools
      names = tools.map(&:name)
      expect(names).to include("glob")
    end

    it "excludes tools disabled in config" do
      described_class.register(Rubino::Tools::ShellTool.new)
      # shell now ships ON by default; flip it off here to exercise the gate.
      Rubino.configuration.set("tools", "shell", false)
      tools = described_class.enabled_tools
      expect(tools.map(&:name)).not_to include("shell")
    ensure
      Rubino.configuration.set("tools", "shell", true)
    end

    it "never returns an empty list when tools are registered and config is default" do
      described_class.register(Rubino::Tools::GlobTool.new)
      described_class.register(Rubino::Tools::GrepTool.new)
      expect(described_class.enabled_tools).not_to be_empty
    end

    # Regression: the config key used to be string-munged from the tool name
    # ("webfetch"/"websearch"), so `tools.web: false` (the shipped gate) was
    # never queried and web tools stayed enabled on a sandboxed VM. Now both
    # tools declare config_key "web" and the registry consults it.
    context "tools.web gate (webfetch + websearch share it)" do
      before do
        described_class.register(Rubino::Tools::WebFetchTool.new)
        described_class.register(Rubino::Tools::WebSearchTool.new)
      end

      it "enables both web tools when tools.web is true" do
        Rubino.configuration.set("tools", "web", true)
        names = described_class.enabled_tools.map(&:name)
        expect(names).to include("webfetch", "websearch")
      ensure
        Rubino.configuration.set("tools", "web", false)
      end

      it "disables BOTH webfetch and websearch when tools.web is false" do
        Rubino.configuration.set("tools", "web", false)
        names = described_class.enabled_tools.map(&:name)
        expect(names).not_to include("webfetch")
        expect(names).not_to include("websearch")
      end
    end
  end
end

# ---------------------------------------------------------------------------
# Tools::Base#config_key — single source of truth for the tools.<key> gate
# ---------------------------------------------------------------------------
RSpec.describe "Tools config_key resolution" do
  it "defaults to the tool name" do
    expect(Rubino::Tools::GlobTool.new.config_key).to eq("glob")
  end

  it "maps webfetch and websearch to the shared 'web' key" do
    expect(Rubino::Tools::WebFetchTool.new.config_key).to eq("web")
    expect(Rubino::Tools::WebSearchTool.new.config_key).to eq("web")
  end
end

# ---------------------------------------------------------------------------
# ToolsCommand — reports enabled/disabled with the SAME resolution as Registry
# ---------------------------------------------------------------------------
RSpec.describe Rubino::CLI::ToolsCommand do
  let(:ui) { Rubino::UI::Null.new }

  before do
    allow(Rubino).to receive(:ui).and_return(ui)
    Rubino::Tools::Registry.register_defaults!
  end

  def web_status
    described_class.new.execute
    table = ui.messages.find { |m| m[:level] == :table }
    row = table[:message][:rows].find { |(key, _)| key == "web" }
    row&.last
  end

  it "reports web as disabled when tools.web is false (matches registry)" do
    Rubino.configuration.set("tools", "web", false)
    expect(web_status).to eq("disabled")
  end

  it "reports web as enabled when tools.web is true (matches registry)" do
    Rubino.configuration.set("tools", "web", true)
    expect(web_status).to eq("enabled")
  ensure
    Rubino.configuration.set("tools", "web", false)
  end

  it "does not list the dead 'browser' key" do
    described_class.new.execute
    table = ui.messages.find { |m| m[:level] == :table }
    keys = table[:message][:rows].map(&:first)
    expect(keys).not_to include("browser")
  end
end

# ---------------------------------------------------------------------------
# EditTool — gsub block form: backslash sequences in new_string are literal
# ---------------------------------------------------------------------------
RSpec.describe Rubino::Tools::EditTool do
  subject(:tool) { described_class.new }

  let(:tmp_dir) { Dir.mktmpdir("edit_fix_spec") }

  before { Rubino.configuration.set("terminal", "cwd", tmp_dir) }

  after do
    Rubino.configuration.set("terminal", "cwd", nil)
    FileUtils.rm_rf(tmp_dir)
  end

  def write_file(name, content)
    path = File.join(tmp_dir, name)
    File.write(path, content)
    path
  end

  describe "backslash sequences in new_string are treated as literals" do
    it "keeps \\0 literally in the replacement" do
      path = write_file("a.rb", "hello world")
      tool.call("file_path" => path, "old_string" => "world", "new_string" => "\\0")
      expect(File.read(path)).to eq("hello \\0")
    end

    it "keeps \\1 literally in the replacement" do
      path = write_file("b.rb", "foo bar")
      tool.call("file_path" => path, "old_string" => "bar", "new_string" => "\\1")
      expect(File.read(path)).to eq("foo \\1")
    end

    it "keeps \\& literally in the replacement" do
      path = write_file("c.rb", "abc")
      tool.call("file_path" => path, "old_string" => "abc", "new_string" => "\\&")
      expect(File.read(path)).to eq("\\&")
    end

    it "replaces all occurrences literally with replace_all" do
      path = write_file("d.rb", "x x x")
      tool.call("file_path" => path, "old_string" => "x", "new_string" => "\\0", "replace_all" => true)
      expect(File.read(path)).to eq("\\0 \\0 \\0")
    end
  end
end

# ---------------------------------------------------------------------------
# PatchTool — new_file and delete_file detection before @@ header
# ---------------------------------------------------------------------------
RSpec.describe Rubino::Tools::PatchTool do
  subject(:tool) { described_class.new }

  let(:tmp_dir) { Dir.mktmpdir("patch_fix_spec") }

  before { Rubino.configuration.set("terminal", "cwd", tmp_dir) }

  after do
    Rubino.configuration.set("terminal", "cwd", nil)
    FileUtils.rm_rf(tmp_dir)
  end

  describe "new file creation (--- /dev/null appears before @@)" do
    it "creates the file when the patch adds a new file" do
      patch = <<~PATCH
        --- /dev/null
        +++ b/new_file.txt
        @@ -0,0 +1,2 @@
        +line one
        +line two
      PATCH

      result = tool.call("patch" => patch, "base_path" => tmp_dir)
      expect(result).to include("Created")
      expect(File.exist?(File.join(tmp_dir, "new_file.txt"))).to be true
      expect(File.read(File.join(tmp_dir, "new_file.txt"))).to include("line one")
    end
  end

  describe "file deletion (+++ /dev/null appears before @@)" do
    it "deletes the file when the patch removes it" do
      existing = File.join(tmp_dir, "to_delete.txt")
      File.write(existing, "old content\n")

      # Real git diff format: --- a/file comes first, then +++ /dev/null
      patch = <<~PATCH
        --- a/to_delete.txt
        +++ /dev/null
        @@ -1,1 +0,0 @@
        -old content
      PATCH

      result = tool.call("patch" => patch, "base_path" => tmp_dir)
      expect(result).to include("Deleted")
      expect(File.exist?(existing)).to be false
    end
  end

  describe "normal hunk patch" do
    it "modifies an existing file" do
      path = File.join(tmp_dir, "code.rb")
      File.write(path, "def foo\n  1\nend\n")

      patch = <<~PATCH
        --- a/code.rb
        +++ b/code.rb
        @@ -1,3 +1,3 @@
         def foo
        -  1
        +  2
         end
      PATCH

      result = tool.call("patch" => patch, "base_path" => tmp_dir)
      expect(result).to include("Patched")
      expect(File.read(path)).to include("  2")
    end
  end
end

# ---------------------------------------------------------------------------
# RubyTool — timeout fallback when agent_max_turn_seconds is nil
# ---------------------------------------------------------------------------
RSpec.describe Rubino::Tools::RubyTool do
  subject(:tool) { described_class.new }

  it "evaluates simple Ruby and returns the result" do
    result = tool.call("code" => "1 + 1")
    expect(result).to eq("2")
  end

  it "returns an error message for syntax errors" do
    result = tool.call("code" => "def incomplete(")
    expect(result).to include("Error")
  end

  it "returns an error message for runtime errors" do
    result = tool.call("code" => "raise 'boom'")
    expect(result).to include("Error")
    expect(result).to include("boom")
  end

  it "does not hang when agent_max_turn_seconds is nil" do
    allow(Rubino.configuration).to receive(:agent_max_turn_seconds).and_return(nil)
    # Should use default 30 s and complete well within that
    result = nil
    expect do
      Timeout.timeout(5) { result = tool.call("code" => "42") }
    end.not_to raise_error
    expect(result).to eq("42")
  end

  it "times out long-running code" do
    allow(Rubino.configuration).to receive(:agent_max_turn_seconds).and_return(1)
    result = tool.call("code" => "sleep 10")
    expect(result).to include("timed out")
  end

  # Regression: user code requiring a missing gem used to raise LoadError which
  # is NOT a StandardError; it escaped the eval Thread, propagated through
  # thread.join into the run executor's worker, and killed the run silently —
  # the row stayed at "running" forever. The fix is to catch Exception (minus
  # signals) so any user-code failure mode surfaces as a tool error string.
  it "catches LoadError from `require` in user code (regression: zombie run)" do
    result = tool.call("code" => %(require "definitely-not-a-real-gem-#{Process.pid}"))
    expect(result).to include("Error")
    expect(result).to include("LoadError")
  end

  it "catches NoMemoryError surface from user code" do
    # We don't actually exhaust memory — we raise it explicitly to prove the
    # rescue catches Exception subclasses outside StandardError.
    result = tool.call("code" => "raise NoMemoryError, 'simulated'")
    expect(result).to include("Error")
    expect(result).to include("NoMemoryError")
  end
end

# ---------------------------------------------------------------------------
# GrepTool — IO.popen argv form prevents shell injection
# ---------------------------------------------------------------------------
RSpec.describe Rubino::Tools::GrepTool do
  subject(:tool) { described_class.new }

  let(:tmp_dir) { Dir.mktmpdir("grep_fix_spec") }

  after { FileUtils.rm_rf(tmp_dir) }

  before do
    File.write(File.join(tmp_dir, "safe.rb"), "hello world\n")
  end

  it "finds a basic pattern without raising" do
    raw    = tool.call("pattern" => "hello", "path" => tmp_dir)
    result = raw.is_a?(Hash) ? (raw[:output] || raw["output"]) : raw
    expect(result).to include("match")
  end

  it "does not execute shell commands embedded in the pattern" do
    # A real shell injection would create /tmp/pwned; verify it does NOT happen
    sentinel = "/tmp/grep_injection_test_#{Process.pid}"
    FileUtils.rm_f(sentinel)

    tool.call("pattern" => "x; touch #{sentinel}", "path" => tmp_dir)
    expect(File.exist?(sentinel)).to be false
  ensure
    FileUtils.rm_f(sentinel)
  end
end

# ---------------------------------------------------------------------------
# GitTool — IO.popen argv form prevents shell injection
# ---------------------------------------------------------------------------
RSpec.describe Rubino::Tools::GitTool do
  subject(:tool) { described_class.new }

  it "does not execute shell commands embedded in args" do
    sentinel = "/tmp/git_injection_test_#{Process.pid}"
    FileUtils.rm_f(sentinel)

    # Even if git is not available this should not execute the injected command
    tool.call("command" => "status", "args" => "; touch #{sentinel}")
    expect(File.exist?(sentinel)).to be false
  ensure
    FileUtils.rm_f(sentinel)
  end

  it "returns a string result for the status command" do
    result = tool.call("command" => "status")
    expect(result).to be_a(String)
  end
end

# ---------------------------------------------------------------------------
# QuestionTool — multiple selection now works
# ---------------------------------------------------------------------------
RSpec.describe Rubino::Tools::QuestionTool do
  subject(:tool) { described_class.new }

  let(:mock_ui) do
    ui = Rubino::UI::Null.new
    allow(ui).to receive(:ask).and_return(answer)
    ui
  end

  before { allow(Rubino).to receive(:ui).and_return(mock_ui) }

  context "single selection" do
    let(:answer) { "1" }

    it "returns the selected option label" do
      result = tool.call(
        "question" => "Pick one?",
        "options" => [{ "label" => "Alpha" }, { "label" => "Beta" }]
      )
      expect(result).to include("Alpha")
    end
  end

  context "multiple selection" do
    let(:answer) { "1, 2" }

    it "returns all selected labels when multiple is true" do
      result = tool.call(
        "question" => "Pick many?",
        "options" => [{ "label" => "Alpha" }, { "label" => "Beta" }],
        "multiple" => true
      )
      expect(result).to include("Alpha")
      expect(result).to include("Beta")
    end
  end

  context "freeform answer" do
    let(:answer) { "custom text" }

    it "returns the freeform answer when no options are given" do
      result = tool.call("question" => "What is your name?")
      expect(result).to include("custom text")
    end
  end
end
