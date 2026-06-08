# frozen_string_literal: true

require "tmpdir"
require "fileutils"

# Smoke spec: just loading UI::LineInput must not blow up.
#
# Regression: the previous chat_command_spec mocked
# setup_readline_completions, so the autoload never fired and a missing
# `reline` runtime dep slipped past the suite. Ruby 4.0 removed reline
# from default gems — this spec catches that class of breakage.
RSpec.describe Rubino::UI::LineInput do
  let(:commands) { %w[/help /exit /quit /commands /skills /mode] }

  it "loads without raising (reline must be available at runtime)" do
    expect { described_class.new }.not_to raise_error
  end

  describe "#configure_completion" do
    it "accepts an empty command list" do
      expect { described_class.new.configure_completion(commands: []) }.not_to raise_error
    end

    it "accepts slash-command names" do
      expect { described_class.new.configure_completion(commands: %w[/help /exit]) }.not_to raise_error
    end

    it "enables Reline autocompletion so candidates render as a dropdown" do
      described_class.new.configure_completion(commands: commands)
      expect(Reline.autocompletion).to be(true)
    end

    it "keeps the completion append character" do
      described_class.new.configure_completion(commands: commands)
      expect(Reline.completion_append_character).to eq(" ")
    end

    it "enables case-insensitive completion for the @file picker" do
      described_class.new.configure_completion(commands: commands)
      expect(Reline.completion_case_fold).to be(true)
    end

    describe "the installed completion_proc" do
      subject(:candidates) { Reline.completion_proc.call(input) }

      # @ resolves to the workspace file list; point it at a temp dir so the
      # slash/plain-text branches are tested without touching the real repo.
      before do
        described_class.new.configure_completion(commands: commands, files: -> { Dir.mktmpdir })
      end

      context "with a bare slash" do
        let(:input) { "/" }

        it "returns every slash command" do
          expect(candidates).to match_array(commands)
        end
      end

      context "with a slash prefix" do
        let(:input) { "/c" }

        it "filters to commands sharing the prefix" do
          expect(candidates).to eq(%w[/commands])
        end
      end

      context "with plain text" do
        let(:input) { "hello" }

        it "returns no candidates" do
          expect(candidates).to be_empty
        end
      end
    end
  end

  describe "arrow-key dropdown navigation bindings" do
    it "lands the CSI + SS3 arrow keys in @additional_key_bindings after configure" do
      described_class.new.configure_completion(commands: commands)

      kb = Reline.core.config
             .instance_variable_get(:@additional_key_bindings)[:emacs]
             .instance_variable_get(:@key_bindings)

      expect(kb[[27, 91, 65]]).to eq(:completion_or_up)   # \e[A
      expect(kb[[27, 91, 66]]).to eq(:completion_or_down) # \e[B
      expect(kb[[27, 79, 65]]).to eq(:completion_or_up)   # \eOA
      expect(kb[[27, 79, 66]]).to eq(:completion_or_down) # \eOB
      expect(kb[[27]]).to eq(:dismiss_completion_dialog)  # \e (L8)
    end

    it "prepends RelineDropdownNav into Reline::LineEditor" do
      expect(Reline::LineEditor.ancestors).to include(Rubino::UI::RelineDropdownNav)
    end
  end

  # The nav actions live in the prepended module; exercise them on a stub that
  # mimics the relevant LineEditor ivars/methods so we don't drive a real TTY.
  describe Rubino::UI::RelineDropdownNav do
    let(:editor_class) do
      Class.new do
        include Rubino::UI::RelineDropdownNav

        attr_accessor :config, :completion_journey_state, :dialogs,
                      :completion_occurs, :moved, :history_calls

        def initialize
          @history_calls = []
        end

        def completion_journey_move(direction)
          @moved = direction
        end

        def ed_prev_history(_key)
          @history_calls << :prev
        end

        def ed_next_history(_key)
          @history_calls << :next
        end

        def ed_unassigned(_key)
          @history_calls << :unassigned
        end
      end
    end

    let(:dialog) do
      Struct.new(:name, :contents).new(:autocomplete, ["a", "b"])
    end

    let(:open_config) { Struct.new(:autocompletion).new(true) }

    subject(:editor) { editor_class.new }

    context "when the dropdown is open" do
      before do
        editor.config = open_config
        editor.completion_journey_state = Object.new
        editor.dialogs = [dialog]
      end

      it "is dropdown_open?" do
        expect(editor.dropdown_open?).to be(true)
      end

      it "completion_or_up navigates the journey and arms @completion_occurs" do
        editor.completion_or_up(:key)
        expect(editor.moved).to eq(:up)
        expect(editor.completion_occurs).to be(true)
        expect(editor.history_calls).to be_empty
      end

      it "completion_or_down navigates the journey and arms @completion_occurs" do
        editor.completion_or_down(:key)
        expect(editor.moved).to eq(:down)
        expect(editor.completion_occurs).to be(true)
        expect(editor.history_calls).to be_empty
      end

      it "dismiss_completion_dialog tears down the journey and clears the dialog (L8)" do
        editor.completion_occurs = true
        editor.dismiss_completion_dialog(:key)
        expect(editor.completion_journey_state).to be_nil
        expect(editor.completion_occurs).to be(false)
        expect(dialog.contents).to be_nil
        # It does NOT fall through to the no-op when the dialog was open.
        expect(editor.history_calls).to be_empty
      end
    end

    # F7: clamp the journey at both ends instead of letting Reline's modulo wrap
    # drop the pointer onto the raw target (index 0), which renders as "no
    # selection" and visually collapses the dropdown. The journey list is
    # [target, candidate1, …]; real candidates occupy index 1..size-1.
    context "clamping at the journey boundaries (F7)" do
      let(:journey) { Struct.new(:pointer, :list) }

      before do
        editor.config = open_config
        editor.dialogs = [dialog]
      end

      it "does NOT move down when already on the last candidate" do
        editor.completion_journey_state = journey.new(2, ["/", "/help", "/exit"])
        editor.completion_or_down(:key)
        expect(editor.moved).to be_nil
        expect(editor.completion_occurs).to be(true) # still keeps the menu armed
      end

      it "moves down when not yet on the last candidate" do
        editor.completion_journey_state = journey.new(1, ["/", "/help", "/exit"])
        editor.completion_or_down(:key)
        expect(editor.moved).to eq(:down)
      end

      it "does NOT move up below the first candidate (index 1)" do
        editor.completion_journey_state = journey.new(1, ["/", "/help", "/exit"])
        editor.completion_or_up(:key)
        expect(editor.moved).to be_nil
        expect(editor.completion_occurs).to be(true)
      end

      it "moves up when above the first candidate" do
        editor.completion_journey_state = journey.new(2, ["/", "/help", "/exit"])
        editor.completion_or_up(:key)
        expect(editor.moved).to eq(:up)
      end
    end

    # F8: ESC must cancel a half-typed slash command, not just close the menu.
    context "ESC clears the in-progress slash command (F8)" do
      let(:editor_with_line_class) do
        Class.new(editor_class) do
          attr_accessor :line, :cleared_to
          def current_line = @line
          def set_current_line(line, byte_pointer = nil)
            @line = line
            @cleared_to = byte_pointer
          end
        end
      end

      subject(:editor) { editor_with_line_class.new }

      before do
        editor.config = open_config
        editor.completion_journey_state = Object.new
        editor.dialogs = [dialog]
      end

      it "clears a `/token` buffer on ESC" do
        editor.line = "/xyz"
        editor.dismiss_completion_dialog(:key)
        expect(editor.line).to eq("")
        expect(editor.cleared_to).to eq(0)
      end

      it "leaves a non-slash buffer untouched" do
        editor.line = "real work in progress"
        editor.dismiss_completion_dialog(:key)
        expect(editor.line).to eq("real work in progress")
      end
    end

    context "when the dropdown is not open" do
      before do
        editor.config = open_config
        editor.completion_journey_state = nil
        editor.dialogs = []
      end

      it "is not dropdown_open?" do
        expect(editor.dropdown_open?).to be(false)
      end

      it "completion_or_up falls back to ed_prev_history" do
        editor.completion_or_up(:key)
        expect(editor.history_calls).to eq([:prev])
        expect(editor.moved).to be_nil
      end

      it "completion_or_down falls back to ed_next_history" do
        editor.completion_or_down(:key)
        expect(editor.history_calls).to eq([:next])
        expect(editor.moved).to be_nil
      end

      it "dismiss_completion_dialog is a no-op (ed_unassigned) when no dialog is open" do
        editor.dismiss_completion_dialog(:key)
        expect(editor.history_calls).to eq([:unassigned])
      end
    end

    it "is not open when autocompletion is disabled even with a dialog showing" do
      editor.config = Struct.new(:autocompletion).new(false)
      editor.completion_journey_state = Object.new
      editor.dialogs = [dialog]
      expect(editor.dropdown_open?).to be(false)
    end
  end

  describe "@ workspace file picker" do
    around do |example|
      Dir.mktmpdir do |dir|
        @root = dir
        example.run
      end
    end

    def configure_with_root(root = @root)
      li = described_class.new
      li.configure_completion(commands: commands, files: -> { root })
      li
    end

    def complete(input)
      Reline.completion_proc.call(input)
    end

    context "in a git workspace" do
      before do
        FileUtils.mkdir_p(File.join(@root, "lib"))
        FileUtils.mkdir_p(File.join(@root, "node_modules", "junk"))
        File.write(File.join(@root, "lib", "foo.rb"), "x")
        File.write(File.join(@root, "lib", "bar.rb"), "x")
        File.write(File.join(@root, "node_modules", "junk", "dep.rb"), "x")
        File.write(File.join(@root, ".gitignore"), "node_modules/\n")
        Dir.chdir(@root) do
          system("git init -q && git add -A && git -c user.email=t@t -c user.name=t commit -qm init",
                 out: File::NULL, err: File::NULL)
        end
        configure_with_root
      end

      it "returns @-prefixed candidates prefix-matching the partial" do
        expect(complete("@l")).to include("@lib/foo.rb", "@lib/bar.rb")
      end

      it "ignores .gitignored dirs (node_modules)" do
        expect(complete("@")).not_to include("@node_modules/junk/dep.rb")
      end

      it "returns [] for a non-matching partial" do
        expect(complete("@zzz")).to eq([])
      end
    end

    it "respects the workspace_root from the files proc" do
      File.write(File.join(@root, "only_here.txt"), "x")
      Dir.chdir(@root) do
        system("git init -q && git add -A && git -c user.email=t@t -c user.name=t commit -qm init",
               out: File::NULL, err: File::NULL)
      end
      # cwd is NOT @root, but the proc points discovery at @root.
      Dir.mktmpdir do |other|
        Dir.chdir(other) do
          li = described_class.new
          li.configure_completion(commands: commands, files: -> { @root })
          expect(Reline.completion_proc.call("@only")).to eq(["@only_here.txt"])
        end
      end
    end

    it "caps candidates at MAX_CANDIDATES" do
      Dir.chdir(@root) do
        50.times { |i| File.write("match_#{i}.txt", "x") }
        system("git init -q && git add -A && git -c user.email=t@t -c user.name=t commit -qm init",
               out: File::NULL, err: File::NULL)
      end
      configure_with_root
      expect(complete("@match").size).to eq(described_class::MAX_CANDIDATES)
    end

    it "degrades to [] when discovery is unavailable" do
      li = configure_with_root
      allow(li).to receive(:discover_files).and_return([])
      expect(Reline.completion_proc.call("@l")).to eq([])
    end

    describe "discovery tier fallback (git -> rg -> glob)" do
      subject(:li) { configure_with_root }

      before do
        File.write(File.join(@root, "plain.rb"), "x")
      end

      it "uses git when available" do
        allow(li).to receive(:git_files).and_return(["from_git.rb"])
        expect(li.send(:discover_files, @root)).to eq(["from_git.rb"])
      end

      it "falls through to rg when git fails" do
        allow(li).to receive(:git_files).and_return(nil)
        allow(li).to receive(:rg_files).and_return(["from_rg.rb"])
        expect(li.send(:discover_files, @root)).to eq(["from_rg.rb"])
      end

      it "falls through to a glob walk when git and rg both fail" do
        allow(li).to receive(:git_files).and_return(nil)
        allow(li).to receive(:rg_files).and_return(nil)
        expect(li.send(:discover_files, @root)).to include("plain.rb")
      end

      it "the glob fallback skips the hardcoded ignore dirs" do
        FileUtils.mkdir_p(File.join(@root, ".git"))
        File.write(File.join(@root, ".git", "config"), "x")
        FileUtils.mkdir_p(File.join(@root, "node_modules"))
        File.write(File.join(@root, "node_modules", "x.rb"), "x")
        result = li.send(:glob_files, @root)
        expect(result).to include("plain.rb")
        expect(result).not_to include(a_string_starting_with(".git/"))
        expect(result).not_to include(a_string_starting_with("node_modules/"))
      end
    end
  end

  describe "#highlight_line (output_modifier_proc)" do
    subject(:line_input) { described_class.new }

    # Force coloring on regardless of the test tty so the substitution is visible.
    before { line_input.instance_variable_set(:@pastel, Pastel.new(enabled: true)) }

    it "leaves plain text unchanged" do
      expect(line_input.send(:highlight_line, "just text\n", complete: false)).to eq("just text\n")
    end

    it "colorizes a leading /command token" do
      result = line_input.send(:highlight_line, "/help\n", complete: false)
      expect(result).to eq("\e[36m/help\e[0m\n")
    end

    it "colorizes a leading @mention token only" do
      result = line_input.send(:highlight_line, "@bob hi\n", complete: false)
      expect(result).to eq("\e[36m@bob\e[0m hi\n")
    end

    it "returns non-string input untouched" do
      expect(line_input.send(:highlight_line, nil)).to be_nil
    end
  end

  describe "#readline initial draft pre-fill" do
    subject(:line_input) { described_class.new }

    before { allow(Reline).to receive(:readline).and_return("") }
    after  { Reline.pre_input_hook = nil }

    it "installs a pre_input_hook that inserts the carried-over draft" do
      expect(Reline).to receive(:insert_text).with("ciao mondo")

      allow(Reline).to receive(:readline) do
        Reline.pre_input_hook&.call # simulate Reline firing the hook
        ""
      end

      line_input.readline("> ", initial: "ciao mondo")
    end

    it "leaves no pre_input_hook set with no initial (next prompt starts empty)" do
      line_input.readline("> ")
      expect(Reline.pre_input_hook).to be_nil
    end

    it "clears the hook after the call even when an initial was given" do
      line_input.readline("> ", initial: "draft")
      expect(Reline.pre_input_hook).to be_nil
    end

    it "treats an empty initial as no pre-fill" do
      expect(Reline).not_to receive(:insert_text)
      allow(Reline).to receive(:readline) do
        Reline.pre_input_hook&.call
        ""
      end
      line_input.readline("> ", initial: "")
    end

    # F1-residual: under a long completion turn Reline intermittently opens the
    # read loop WITHOUT firing the pre_input_hook, silently dropping the draft.
    # The deterministic fallback prepends the seed so the half-typed draft is
    # never lost regardless of Reline's hook timing.
    it "prepends the draft when Reline never fires the hook (deterministic carry-over)" do
      # Simulate the fragile case: the hook is installed but Reline returns
      # without ever calling it, and the user submits an empty line.
      allow(Reline).to receive(:readline).and_return("")

      expect(line_input.readline("> ", initial: "half typed")).to eq("half typed")
    end

    it "prepends the draft to whatever the user typed when the hook never fires" do
      allow(Reline).to receive(:readline).and_return(" rest of sentence")

      expect(line_input.readline("> ", initial: "half typed"))
        .to eq("half typed rest of sentence")
    end

    it "does NOT double-apply the draft when the hook fired normally" do
      # Hook fires and inserts; the returned line already carries the seed.
      allow(Reline).to receive(:insert_text)
      allow(Reline).to receive(:readline) do
        Reline.pre_input_hook&.call
        "half typed and more"
      end

      expect(line_input.readline("> ", initial: "half typed"))
        .to eq("half typed and more")
    end

    it "leaves a nil line (Ctrl-C / EOF) untouched even when the hook never fires" do
      allow(Reline).to receive(:readline).and_return(nil)

      expect(line_input.readline("> ", initial: "half typed")).to be_nil
    end
  end
end
