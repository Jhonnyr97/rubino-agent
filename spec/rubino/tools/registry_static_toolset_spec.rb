# frozen_string_literal: true

# The model-visible tool set is STATIC for the whole session: it does NOT change
# when a background shell or a subagent appears/disappears. This is a KV /
# prompt-cache invariant — the `tools` block is prefilled as part of the prompt
# PREFIX on local single-slot inference servers (openai-compatible, no Anthropic
# cache_control breakpoint), so mutating it mid-session busts the entire KV cache
# and forces a full re-prefill. We previously hid steer + shell_* until a
# child/background-shell existed (#313); that toggled the tools block as shells
# came and went and re-prefilled the whole context on every cycle. Now every tool
# is registered once and never situationally hidden (supersedes #313), matching
# Codex / Claude Code / OpenCode / aider which all keep a static tool list.
RSpec.describe Rubino::Tools::Registry do
  before do
    Rubino.loader.eager_load
    described_class.register_defaults!
  end

  def enabled_names
    described_class.enabled_tools.map(&:name)
  end

  describe "shell-management tools are always exposed" do
    it "exposes shell_input/output/tail/kill even with NO background shell" do
      allow(Rubino::Tools::ShellRegistry.instance).to receive(:any?).and_return(false)
      %w[shell_input shell_output shell_tail shell_kill].each do |t|
        expect(enabled_names).to include(t)
      end
    end

    it "keeps the exact same shell tools once a background shell exists" do
      allow(Rubino::Tools::ShellRegistry.instance).to receive(:any?).and_return(true)
      %w[shell shell_input shell_output shell_tail shell_kill].each do |t|
        expect(enabled_names).to include(t)
      end
    end
  end

  describe "subagent-comm tools are always exposed" do
    it "exposes steer (and the poll tools) even with NO child task" do
      allow(Rubino::Tools::BackgroundTasks.instance).to receive(:list).and_return([])
      %w[task task_result task_stop steer probe].each do |t|
        expect(enabled_names).to include(t)
      end
    end

    it "still drops task AND its poll tools when tools.task is disabled (config gate intact)" do
      cfg = Marshal.load(Marshal.dump(Rubino.configuration))
      cfg.set("tools", "task", false)
      allow(Rubino).to receive(:configuration).and_return(cfg)
      %w[task task_result task_stop probe].each do |t|
        expect(enabled_names).not_to include(t)
      end
    end
  end

  describe "tool schema is byte-identical regardless of lifecycle state (the KV invariant)" do
    it "produces the same tool_definitions whether or not a shell/child exists" do
      allow(Rubino::Tools::BackgroundTasks.instance).to receive(:list).and_return([])
      allow(Rubino::Tools::ShellRegistry.instance).to receive(:any?).and_return(false)
      before_any = JSON.generate(described_class.tool_definitions)

      allow(Rubino::Tools::BackgroundTasks.instance).to receive(:list).and_return([Object.new])
      allow(Rubino::Tools::ShellRegistry.instance).to receive(:any?).and_return(true)
      after_any = Rubino.with_current_subagent_id("sa_x") { JSON.generate(described_class.tool_definitions) }

      expect(after_any).to eq(before_any)
    end
  end
end
