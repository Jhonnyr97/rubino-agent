# frozen_string_literal: true

RSpec.describe Rubino::Agent::ActionClaimGuard do
  subject(:guard) { described_class.new(exposed_tool_names: all_tools) }

  # The full toolset the model normally has — verbs only fire when their backing
  # tool is on offer this turn.
  let(:all_tools) do
    %w[shell ruby test write edit multi_edit patch git github read grep web_fetch]
  end

  def verdict(text, tool_count: 0, denied_count: 0)
    guard.evaluate(content: text, tool_count: tool_count, denied_count: denied_count)
  end

  describe "fabricated action claims with ZERO tool calls (the r5 trust-killer)" do
    # These are the verbatim / paraphrased narrations from the r5 reports that
    # ended a turn with `0 tools` and let a fake success reach the user.
    it "flags the bare-lead 'Running the suite now.' (r5 F1)" do
      expect(verdict("Running the suite now.")).to eq([:reflect, "run"])
    end

    it "flags the post-deny 'Saved to <path> and ran it:' fabrication (r5 ux-first F1)" do
      text = "Saved to /home/dev/myproj/hello.py and ran it:\n\n```\nHello, world!\n```"
      expect(verdict(text).first).to eq(:reflect)
    end

    it "flags 'I'll remove mode() ... Then re-run the tests.' (r5 F1 removal)" do
      expect(verdict("I'll remove mode() from both files. Then re-run the tests.").first)
        .to eq(:reflect)
    end

    it "flags first-person past-participle 'I've written ... and executed it.'" do
      expect(verdict("I've written test_stats.py and executed it.").first).to eq(:reflect)
    end

    it "flags completion-lead 'Done — created the file.'" do
      expect(verdict("Done — created the file.").first).to eq(:reflect)
    end

    it "flags 'I ran the tests and they all pass.'" do
      expect(verdict("I ran the tests and they all pass.").first).to eq(:reflect)
    end
  end

  describe "cd / change-directory intent (rubino has no cd tool — MF-3)" do
    it "rewrites a 'cd /x' claim with the honest no-cd message" do
      kind, msg = verdict("cd /tmp/somewhere-else — done.")
      expect(kind).to eq(:cd)
      expect(msg).to include("no `cd` tool").or include("can't change my working directory")
      expect(msg).to include("/add-dir")
    end

    it "rewrites 'I changed the working directory ...'" do
      expect(verdict("I changed the working directory to /tmp/foo and confirmed.").first)
        .to eq(:cd)
    end

    it "rewrites a bare 'Changed directory to /x.'" do
      expect(verdict("Changed directory to /x.").first).to eq(:cd)
    end

    it "does NOT flag 2nd-person cd ADVICE to the user" do
      text = "cd into the repo and run make — that's how you'd build it yourself."
      expect(verdict(text)).to be_nil
    end
  end

  describe "legitimate turns it must NEVER nag" do
    it "ignores describing how the user can act ('You can run the tests ...')" do
      expect(verdict("You can run the tests with `pytest`.")).to be_nil
    end

    it "ignores advice ('To save the file, use the write tool.')" do
      expect(verdict("To save the file, use the write tool.")).to be_nil
    end

    it "ignores a command shown as reference, not claimed as done" do
      expect(verdict("The test command is `bundle exec rspec`.")).to be_nil
    end

    it "ignores a turn that ENDS by asking the user (a clarify)" do
      expect(verdict("Would you like me to run the tests?")).to be_nil
      expect(verdict("I can write a test file if you want — shall I?")).to be_nil
    end

    it "ignores a plain explanatory answer with no action claim" do
      expect(verdict("Here's the median fix; it averages the two middle values.")).to be_nil
      expect(verdict("The output is:\n\n```\nhello\n```")).to be_nil
    end

    it "ignores empty / whitespace content" do
      expect(verdict("")).to be_nil
      expect(verdict("   \n  ")).to be_nil
    end

    it "ignores an honest non-completion that mentions the action ('I can't run it because…')" do
      expect(verdict("I'd run the tests, but I can't — there is no test file yet.")).to be_nil
      expect(verdict("I tried to write it but I'm unable to: the path is read-only.")).to be_nil
    end
  end

  describe "the guard only judges TOOLLESS turns" do
    it "suppresses when a tool actually ran this turn (real summary, not fabrication)" do
      expect(verdict("Ran the tests; all pass.", tool_count: 2)).to be_nil
    end

    it "suppresses when a tool was DENIED this turn (legit deny-recovery prose)" do
      expect(verdict("Saved the file.", denied_count: 1)).to be_nil
    end
  end

  describe "verb gating on the exposed toolset" do
    it "does NOT flag a web-fetch claim when no fetch-capable tool is exposed" do
      narrow = described_class.new(exposed_tool_names: %w[read grep])
      v = narrow.evaluate(content: "I fetched the page and parsed it.",
                          tool_count: 0, denied_count: 0)
      expect(v).to be_nil
    end

    it "DOES flag a write claim when write is exposed" do
      narrow = described_class.new(exposed_tool_names: %w[write])
      v = narrow.evaluate(content: "I'll write the config file now.",
                          tool_count: 0, denied_count: 0)
      expect(v.first).to eq(:reflect)
    end
  end

  describe "#reflection_message" do
    it "names the claimed verb and demands a tool call or an honest 'cannot'" do
      msg = guard.reflection_message("run")
      expect(msg).to include("run")
      expect(msg).to match(/no tool call/i)
      expect(msg).to match(/tool call to carry it out/i)
    end
  end

  it "caps reflections at 3 (aider parity)" do
    expect(described_class::MAX_REFLECTIONS).to eq(3)
  end
end
