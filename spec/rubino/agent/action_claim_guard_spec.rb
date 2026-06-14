# frozen_string_literal: true

RSpec.describe Rubino::Agent::ActionClaimGuard do
  subject(:guard) { described_class.new(exposed_tool_names: all_tools) }

  # The full toolset the model normally has — verbs only fire when their backing
  # tool is on offer this turn.
  let(:all_tools) do
    %w[shell ruby test write edit multi_edit patch git github read grep web_fetch]
  end

  def verdict(text, tool_count: 0, denied_count: 0, noninteractive: false, terminal: false)
    guard.evaluate(content: text, tool_count: tool_count, denied_count: denied_count,
                   noninteractive: noninteractive, terminal: terminal)
  end

  describe "fabricated action claims with ZERO tool calls (the r5 trust-killer)" do
    # These are the verbatim / paraphrased narrations from the r5 reports that
    # ended a turn with `0 tools` and let a fake success reach the user.
    it "flags the bare-lead 'Running the suite now.' (r5 F1)" do
      expect(verdict("Running the suite now.")).to eq([:reflect, "run that"])
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

  # r5c gate-loop: the three proven gaps where a 0-tool turn surfaced a
  # fabricated file/state MUTATION as the final answer (file unchanged on disk).
  # These FAIL on the pre-fix guard (only first-person/completion-window verbs).
  describe "fabricated file/state MUTATIONS (r5c NEW-1 / B1 — the high-cost class)" do
    it "flags STATE-RESULT phrasing 'Done. <file> now contains X' (r5c NEW-1)" do
      text = 'Done. /home/dev/api/README.md now contains "API v2".'
      expect(verdict(text).first).to eq(:reflect)
    end

    it "flags more state-result shapes (now has / is now set to / now reads)" do
      expect(verdict("The file now has the import at the top.").first).to eq(:reflect)
      expect(verdict("X is now set to 5.").first).to eq(:reflect)
      expect(verdict("The contents now read: API v2.").first).to eq(:reflect)
    end

    it "flags a BUNDLED edit-claim + trailing future intent, on the EDIT (r5c B1)" do
      # Pre-fix the guard challenged only the trailing 'run the tests' sub-claim
      # and let the fabricated multi_edit pass. Now the EDIT is what's flagged.
      text = "Updated both methods to use item instead of it. Running the tests now."
      kind, claim = verdict(text)
      expect(kind).to eq(:reflect)
      expect(claim).to match(/update/i)
    end

    it "flags a FIRST-in-chain mutation claim 'Added the docstring' (r5c B1)" do
      expect(verdict("Added the docstring to count().").first).to eq(:reflect)
    end

    it "flags past-tense mutation verbs asserted anywhere in the message" do
      expect(verdict("Wrote test_stats.py.").first).to eq(:reflect)
      expect(verdict("Removed mode() from both files.").first).to eq(:reflect)
      expect(verdict("I have applied the patch to cart.py.").first).to eq(:reflect)
      expect(verdict("I edited the config and saved it.").first).to eq(:reflect)
      expect(verdict("Created config.rb with the defaults.").first).to eq(:reflect)
    end

    it "does NOT challenge a mutation claim when NO write-family tool is exposed" do
      narrow = described_class.new(exposed_tool_names: %w[read grep shell])
      v = narrow.evaluate(content: "I updated the config file.",
                          tool_count: 0, denied_count: 0)
      expect(v).to be_nil
    end

    it "still does NOT challenge mutation ADVICE / how-to (no false positive)" do
      expect(verdict("You can add a docstring to count() with a triple-quoted string."))
        .to be_nil
      expect(verdict("You should update the import to point at the new module."))
        .to be_nil
      expect(verdict("To save the file, use the write tool.")).to be_nil
    end

    it "does NOT challenge a plain description of file state ('the file contains a bug')" do
      expect(verdict("The file contains a bug in apply_discount.")).to be_nil
      expect(verdict("README.md has the old API version string.")).to be_nil
    end

    it "does NOT challenge an honest non-mutation ('I cannot update it …')" do
      expect(verdict("I cannot update the file — there is no such method.")).to be_nil
    end

    it "does NOT challenge a pure read/answer turn that names a file" do
      expect(verdict("README.md is 62 bytes and starts with '# Orders API'.")).to be_nil
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

    it "suppresses when a tool was DENIED but the prose honestly reports the block" do
      # An honest "blocked / couldn't" answer is a real deny-recovery summary —
      # left alone even though a tool was denied this turn.
      expect(verdict("That tool was blocked, so I couldn't save the file.", denied_count: 1))
        .to be_nil
    end

    it "REPLACES a fabricated success-narration AFTER a tool was denied/blocked (F1/F2)" do
      # When a tool was denied/blocked but the model still narrates success, the
      # claim is a fabrication — the guard must override it with the honest
      # 'blocked, nothing applied' message, not surface the lie.
      kind, msg = verdict("Saved the file.", denied_count: 1)
      expect(kind).to eq(:blocked)
      expect(msg).to match(/blocked/i)
      expect(msg).to match(/nothing was applied/i)
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

  # G1 (CRITICAL): the reflection budget is spent and the poisoned-context model
  # is STILL fabricating a git/file mutation with zero tool calls. The guard must
  # be BINDING — REPLACE the fabricated final answer with an honest deterministic
  # message, never surface the model's "Done … committed as <sha>".
  describe "BINDING terminal override (G1 — guard verdict overrides the model)" do
    it "REPLACES a fabricated git-commit claim on the terminal turn, not :reflect" do
      text = "Done. New branch feature/tax with the cart.rb change committed as 0f60f1d."
      kind, msg = verdict(text, terminal: true)
      expect(kind).to eq(:replace)
      expect(msg).to match(/no tool call was made/i)
      expect(msg).to match(/nothing was changed on disk/i)
      # The fabricated SHA / "Done … committed" must NOT survive in the replacement.
      expect(msg).not_to include("0f60f1d")
      expect(msg).not_to match(/committed as/i)
    end

    it "REPLACES a fabricated file-mutation claim on the terminal turn" do
      kind, msg = verdict("Updated both methods and saved the file.", terminal: true)
      expect(kind).to eq(:replace)
      expect(msg).to match(/i did not/i)
    end

    it "still only REFLECTS (not replaces) before the budget is spent" do
      text = "Done. committed as 0f60f1d."
      expect(verdict(text, terminal: false).first).to eq(:reflect)
    end

    it "leaves a genuine non-claim final answer untouched even on the terminal turn" do
      expect(verdict("Here's how the discount code works in cart.rb.", terminal: true))
        .to be_nil
    end
  end

  # F1/F2 (HIGH): a tool was denied/blocked (headless fail-closed, or user-denied)
  # and the model then narrates success OR hands back a fabricated unified diff
  # for files it never wrote. Replace it with the honest blocked message.
  describe "denied/blocked-but-claims (F1/F2 — never let a fabricated diff stand)" do
    let(:headless_diff) do
      <<~TXT
        The rename is complete and ready to apply with `git apply`:

        --- a/shopkit/invoice.py
        +++ b/shopkit/invoice.py
        @@ -1,4 +1,4 @@
        -from shopkit.pricing import calc_total
        +from shopkit.pricing import compute_subtotal
      TXT
    end

    it "REPLACES a fabricated 'ready to git apply' diff after a headless block (F1)" do
      kind, msg = verdict(headless_diff, denied_count: 1, noninteractive: true)
      expect(kind).to eq(:blocked)
      expect(msg).to match(/blocked/i)
      expect(msg).to include("--yolo")
      # F2: the headless message must name the skip-mode behaviour change.
      expect(msg).to match(/approvals\.mode: skip/i)
      expect(msg).to match(/no longer auto-runs/i)
      # The honest message must NOT present the diff as applyable.
      expect(msg).to match(/not a real, applied change/i)
    end

    it "REPLACES a fabricated diff even with NO narration verb (the diff alone)" do
      diff = "--- a/a.py\n+++ b/a.py\n@@ -1 +1 @@\n-x\n+y\n"
      expect(verdict(diff, denied_count: 1, noninteractive: true).first).to eq(:blocked)
    end

    it "uses the approve-it hatch (not --yolo) for a user-denied block" do
      kind, msg = verdict("Saved the file.", denied_count: 1, noninteractive: false)
      expect(kind).to eq(:blocked)
      expect(msg).to match(/approve the action/i)
      expect(msg).not_to include("--yolo")
    end

    it "leaves an HONEST blocked answer (no success-claim, no diff) untouched" do
      text = "That edit was blocked because there's no interactive session — " \
             "nothing was applied. Re-run with --yolo to allow it."
      expect(verdict(text, denied_count: 1, noninteractive: true)).to be_nil
    end
  end
end
