# frozen_string_literal: true

# #313 — situational tool-schema gating. The Registry hides tools that only make
# sense once a SESSION-STABLE lifecycle signal flips (a subagent exists, a
# background shell exists, or this run IS a subagent), so a normal file-edit
# turn ships ~2k fewer tokens of dead tool definitions. The signals flip at most
# once per session, keeping the cached tool block (#311) byte-stable.
RSpec.describe Rubino::Tools::Registry, "situational gating (#313)" do
  before(:all) { Rubino.loader.eager_load }
  before { described_class.register_defaults! }

  def enabled_names
    described_class.enabled_tools.map(&:name)
  end

  describe "subagent-comm tools" do
    it "hides ask_parent on a top-level run (no parent)" do
      expect(Rubino.current_subagent_id).to be_nil
      expect(enabled_names).not_to include("ask_parent")
    end

    it "exposes ask_parent when running AS a subagent" do
      Rubino.with_current_subagent_id("sa_abc") do
        expect(enabled_names).to include("ask_parent")
      end
    end

    it "hides the child-management tools until ≥1 child task exists" do
      allow(Rubino::Tools::BackgroundTasks.instance).to receive(:list).and_return([])
      %w[task_result task_stop steer probe answer_child].each do |t|
        expect(enabled_names).not_to include(t)
      end
    end

    it "keeps task (spawn) always-on regardless of children" do
      allow(Rubino::Tools::BackgroundTasks.instance).to receive(:list).and_return([])
      expect(enabled_names).to include("task")
    end

    it "exposes the child-management tools once a child task exists" do
      allow(Rubino::Tools::BackgroundTasks.instance).to receive(:list).and_return([Object.new])
      %w[task_result task_stop steer probe answer_child].each do |t|
        expect(enabled_names).to include(t)
      end
    end
  end

  describe "shell-management tools" do
    it "hides shell_input/output/tail/kill until a background shell exists" do
      expect(Rubino::Tools::ShellRegistry.instance.any?).to be(false)
      %w[shell_input shell_output shell_tail shell_kill].each do |t|
        expect(enabled_names).not_to include(t)
      end
    end

    it "keeps shell (spawn) always-on regardless of background shells" do
      expect(enabled_names).to include("shell")
    end

    it "exposes the shell-management tools once a background shell exists" do
      allow(Rubino::Tools::ShellRegistry.instance).to receive(:any?).and_return(true)
      %w[shell_input shell_output shell_tail shell_kill].each do |t|
        expect(enabled_names).to include(t)
      end
    end
  end

  describe "token savings on the common turn" do
    it "drops the situational defs from a normal turn (no child, no bg shell)" do
      allow(Rubino::Tools::BackgroundTasks.instance).to receive(:list).and_return([])
      situational = %w[ask_parent task_result task_stop steer probe answer_child
                       shell_input shell_output shell_tail shell_kill]
      expect(enabled_names & situational).to be_empty
    end

    it "the hidden situational defs are a meaningful fraction of the schema bytes" do
      allow(Rubino::Tools::BackgroundTasks.instance).to receive(:list).and_return([])
      common = described_class.tool_definitions

      # Force every situational signal on, then re-read the full set.
      allow(Rubino::Tools::BackgroundTasks.instance).to receive(:list).and_return([Object.new])
      allow(Rubino::Tools::ShellRegistry.instance).to receive(:any?).and_return(true)
      full = Rubino.with_current_subagent_id("sa_x") { described_class.tool_definitions }

      common_bytes = JSON.generate(common).bytesize
      full_bytes   = JSON.generate(full).bytesize
      # The situational block is real, non-trivial weight (rough proxy for ~2k
      # tokens at ~4 chars/token ⇒ well over 1k bytes saved).
      expect(full_bytes - common_bytes).to be > 1_000
    end
  end
end
