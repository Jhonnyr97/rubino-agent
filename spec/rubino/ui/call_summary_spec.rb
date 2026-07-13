# frozen_string_literal: true

RSpec.describe Rubino::UI::CallSummary do
  let(:workspace_root) { Dir.pwd }

  # Build a test tool class with the given summary spec.
  def tool_class(summary_key: nil, summary_block: nil, relative_to: nil)
    Class.new(Rubino::Tool) do
      abstract!
      define_method(:name) { "test_tool" }

      if summary_block
        summary(&summary_block)
      elsif summary_key
        summary summary_key, relative_to: relative_to
      end
    end
  end

  def tool_instance(tool_class)
    tool_class.new
  end

  describe ".render" do
    describe ":status context" do
      it "returns a single String" do
        tc = tool_class(summary_key: :command)
        result = described_class.render(tc.new, { command: "ls" }, width: 60, context: :status)
        expect(result).to be_a(String)
      end

      it "truncates a long value with …" do
        tc = tool_class(summary_key: :command)
        long_cmd = "x" * 100
        result = described_class.render(tc.new, { command: long_cmd }, width: 30, context: :status)
        expect(result.length).to be <= 30
        expect(result).to end_with("…")
      end

      it "does not truncate when short enough" do
        tc = tool_class(summary_key: :command)
        result = described_class.render(tc.new, { command: "ls" }, width: 60, context: :status)
        expect(result).to eq("test_tool ls")
        expect(result).not_to include("…")
      end

      it "falls back to bare tool name when no arguments" do
        tc = tool_class(summary_key: :file_path)
        result = described_class.render(tc.new, {}, width: 60, context: :status)
        expect(result).to eq("test_tool")
      end
    end

    describe ":approval context" do
      it "returns Array<String>" do
        tc = tool_class(summary_key: :command)
        result = described_class.render(tc.new, { command: "ls" }, width: 80, context: :approval)
        expect(result).to be_an(Array)
      end

      it "does NOT truncate a long command — full fidelity" do
        tc = tool_class(summary_key: :command)
        x200 = "x" * 200
        long_cmd = "echo #{x200}"
        result = described_class.render(tc.new, { command: long_cmd }, width: 40, context: :approval)
        full = result.join
        # Word-aware wrapping may consume the break-space; verify all payload survives.
        expect(full).to include("echo")
        expect(full).to include(x200)
        expect(full).not_to include("…")
        expect(full).not_to include("...")
      end

      it "wraps long lines to width" do
        tc = tool_class(summary_key: :command)
        long_cmd = "x" * 80
        result = described_class.render(tc.new, { command: long_cmd }, width: 40, context: :approval)
        expect(result.size).to be >= 2 # wrapped into multiple lines
      end
    end

    describe ":timeline context" do
      it "does NOT contain 'wants to run' detail from preview_arguments" do
        presentation = Class.new(Rubino::Tools::ToolPresentation) do
          define_method(:preview_arguments) { |_label, _args|
            "wants to run: edit foo.rb\n  - def bar"
          }
        end.new

        klass = Class.new(Rubino::Tool) do
          abstract!
          define_method(:name) { "edit" }
          define_singleton_method(:tool_presentation) { presentation }
          summary :file_path
        end

        result = described_class.render(klass.new, { file_path: "foo.rb" }, width: 80, context: :timeline)
        full = result.join
        expect(full).not_to include("wants to run")
        expect(full).to eq("edit foo.rb")
      end

      it "does NOT contain ellipsis for a long command" do
        tc = tool_class(summary_key: :command)
        x200 = "x" * 200
        long_cmd = "echo #{x200}"
        result = described_class.render(tc.new, { command: long_cmd }, width: 40, context: :timeline)
        full = result.join
        expect(full).not_to include("…")
        expect(full).to include("echo")
        expect(full).to include(x200)
      end
    end

    describe ":trace context" do
      it "returns Array<String>" do
        tc = tool_class(summary_key: :command)
        result = described_class.render(tc.new, { command: "ls" }, width: 0, context: :trace)
        expect(result).to be_an(Array)
        expect(result.first).to eq("test_tool ls")
      end
    end

    describe "secrets masking" do
      it "masks secret values" do
        tc = tool_class(summary_key: :command)
        result = described_class.render(tc.new, { command: "API_KEY=sk-12345 ./run.sh" }, width: 80, context: :approval)
        # The secret should be masked — the exact mask format depends on SecretsMask,
        # but the raw key should NOT appear.
        full = result.join
        expect(full).not_to include("sk-12345")
      end
    end

    describe "terminal escape sanitization" do
      it "strips ANSI escape sequences" do
        tc = tool_class(summary_key: :command)
        evil = "ls \e[31mRED\e[0m"
        result = described_class.render(tc.new, { command: evil }, width: 80, context: :approval)
        full = result.join
        expect(full).not_to include("\e[")
      end
    end

    describe "fallback when no summary spec" do
      it "uses ToolLabel.pick_hint as fallback" do
        klass = Class.new(Rubino::Tool) do
          abstract!
          define_method(:name) { "no_spec_tool" }
        end
        result = described_class.render(klass.new, { command: "ls -la" }, width: 80, context: :approval)
        expect(result.first).to eq("no_spec_tool ls -la")
      end

      it "returns bare tool name when no identifying arg" do
        klass = Class.new(Rubino::Tool) do
          abstract!
          define_method(:name) { "bare_tool" }
        end
        result = described_class.render(klass.new, {}, width: 80, context: :approval)
        expect(result.first).to eq("bare_tool")
      end
    end

    describe "block summary" do
      it "calls the block with symbol-keyed args" do
        klass = Class.new(Rubino::Tool) do
          abstract!
          define_method(:name) { "block_tool" }
          summary { |a| "cmd=#{a[:command]}" }
        end
        result = described_class.render(klass.new, { command: "npm test" }, width: 80, context: :approval)
        expect(result.first).to eq("block_tool cmd=npm test")
      end

      it "calls the block with string-keyed args (BUG 1 regression — real JSON keys)" do
        klass = Class.new(Rubino::Tool) do
          abstract!
          define_method(:name) { "block_tool" }
          summary { |a| "cmd=#{a[:command]}" }
        end
        result = described_class.render(klass.new, { "command" => "npm test" }, width: 80, context: :approval)
        expect(result.first).to eq("block_tool cmd=npm test")
      end
    end

    describe "string-keyed args (BUG 1 regression coverage per tool)" do
      it "renders shell summary with string-keyed command" do
        klass = Class.new(Rubino::Tool) do
          abstract!
          define_method(:name) { "shell" }
          summary { |a| a[:command] }
        end
        result = described_class.render(klass.new, { "command" => "echo hi && ls" }, width: 72, context: :timeline)
        expect(result.first).to eq("shell echo hi && ls")
      end

      it "renders webfetch summary with string-keyed url" do
        klass = Class.new(Rubino::Tool) do
          abstract!
          define_method(:name) { "webfetch" }
          summary { |a| a[:url] }
        end
        result = described_class.render(klass.new, { "url" => "https://example.com" }, width: 80, context: :approval)
        expect(result.first).to eq("webfetch https://example.com")
      end

      it "renders websearch summary with string-keyed query" do
        klass = Class.new(Rubino::Tool) do
          abstract!
          define_method(:name) { "websearch" }
          summary { |a| a[:query] }
        end
        result = described_class.render(klass.new, { "query" => "rubino agent" }, width: 80, context: :approval)
        expect(result.first).to eq("websearch rubino agent")
      end

      it "renders skill summary with string-keyed action and name" do
        klass = Class.new(Rubino::Tool) do
          abstract!
          define_method(:name) { "skill" }
          summary { |a| "#{a[:action] || 'load'} #{a[:name]}" }
        end
        result = described_class.render(klass.new, { "action" => "use", "name" => "ruby-expert" }, width: 80, context: :approval)
        expect(result.first).to eq("skill use ruby-expert")
      end

      it "renders grep summary with string-keyed pattern and path" do
        klass = Class.new(Rubino::Tool) do
          abstract!
          define_method(:name) { "grep" }
          summary { |a, ctx| "#{a[:pattern]} in #{ctx.rel(a[:path] || '.')}" }
        end
        result = described_class.render(klass.new, { "pattern" => "def render", "path" => "lib/foo.rb" }, width: 80, context: :approval)
        expect(result.first).to eq("grep def render in lib/foo.rb")
      end

      it "renders glob summary with string-keyed pattern and path" do
        klass = Class.new(Rubino::Tool) do
          abstract!
          define_method(:name) { "glob" }
          summary { |a, ctx| "#{a[:pattern]} in #{ctx.rel(a[:path] || '.')}" }
        end
        result = described_class.render(klass.new, { "pattern" => "**/*.rb", "path" => "spec" }, width: 80, context: :approval)
        expect(result.first).to eq("glob **/*.rb in spec")
      end
    end

    describe "relative_to: :workspace" do
      it "shows the path relative to the workspace root" do
        klass = Class.new(Rubino::Tool) do
          abstract!
          define_method(:name) { "rel_tool" }
          summary :file_path, relative_to: :workspace
        end
        # Use a path under the workspace
        abs = File.join(workspace_root, "subdir", "file.rb")
        result = described_class.render(klass.new, { file_path: abs }, width: 80, context: :approval)
        expect(result.first).to eq("rel_tool subdir/file.rb")
      end
    end

    describe "word-aware wrapping (BUG 3)" do
      it "wraps a long path at whitespace without splitting a filename token" do
        klass = Class.new(Rubino::Tool) do
          abstract!
          define_method(:name) { "w" }
          summary { |a| a[:command] }
        end
        cmd = "ls tools/mydir/myfile.rb"
        result = described_class.render(klass.new, { command: cmd }, width: 20, context: :approval)

        # When wrapping at whitespace, no piece (other than the first) should
        # start mid-token — the break should be at the space after "ls"
        stripped_lines = result.map { |l| l.sub(/\A  /, "") }
        # First line should be "w ls" (the space is the break point, consumed)
        expect(stripped_lines.first).to eq("w ls")
        # Remaining content should appear in subsequent lines
        remainder = stripped_lines[1..].join
        expect(remainder).to eq("tools/mydir/myfile.rb")
      end

      it "hard-cuts a single over-long token with no data loss" do
        klass = Class.new(Rubino::Tool) do
          abstract!
          define_method(:name) { "w" }
          summary { |a| a[:command] }
        end
        long_token = "x" * 100
        result = described_class.render(klass.new, { command: long_token }, width: 30, context: :approval)

        # Join all pieces, stripping continuation indents — every char must survive.
        # The wrap consumes the break-character space, so "w " + token becomes "w" + token.
        joined = result.join.gsub(/  /, "")
        expect(joined).to eq("w#{long_token}")
      end
    end
  end
end
