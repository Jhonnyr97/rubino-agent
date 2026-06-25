# frozen_string_literal: true

require "stringio"

# BUG 01 at the UI::CLI seam: #ask (the clarification / `question` surface) and
# the approval menu must reconcile the mid-turn type-ahead queue with the prompt
# that opens. #ask PREFILLS a queued line as the editable answer (Symptom C);
# the approval menu DRAINS in-flight keystrokes but never auto-fills a queued
# line into a destructive grant (Symptom B). Driven without a PTY: a real
# BottomComposer (StringIO-backed) is registered as the current composer with a
# parked queue line, and the TTY::Prompt call is stubbed to capture its args.
RSpec.describe Rubino::UI::CLI do
  subject(:cli) { described_class.allocate }

  let(:term_io_class) do
    Class.new(StringIO) do
      def winsize = [24, 80]
    end
  end
  let(:queue)    { Rubino::Interaction::InputQueue.new }
  let(:composer) do
    Rubino::UI::BottomComposer.new(input_queue: queue,
                                   input: StringIO.new, output: term_io_class.new)
  end

  before do
    cli.instance_variable_set(:@prompt, instance_double(TTY::Prompt))
    cli.instance_variable_set(:@approval_handler, nil)
    cli.instance_variable_set(:@budget_handler, nil)
    # #interactive_terminal? returns true the moment a BottomComposer is current
    # (the live-composer branch), so registering one below opens the gate — no
    # need to stub the object under test.
    #
    # The class-method seam suspends/resumes the registered composer — stub the
    # raw-reader lifecycle (a StringIO can't back it) but keep the drain REAL.
    allow(composer).to receive(:suspend)
    allow(composer).to receive(:resume)
    Rubino::UI::BottomComposer.current = composer
  end

  after { Rubino::UI::BottomComposer.current = nil }

  describe "#ask (clarification / question)" do
    it "PREFILLS a queued line as the editable answer (Symptom C regression)" do
      queue.push("use sqlite")

      captured = nil
      allow(cli.instance_variable_get(:@prompt)).to receive(:ask) do |prompt, **kw|
        captured = [prompt, kw]
        kw[:value] # TTY::Prompt#ask returns the (edited) value; here unedited
      end

      answer = cli.ask("Which database?")

      expect(answer).to eq("use sqlite")              # delivered to THIS prompt
      expect(captured).to eq(["Which database?", { value: "use sqlite" }])
      expect(queue.pending?).to be(false)             # NOT left to fire as a new turn
    end

    it "asks plainly (no value:) when nothing is queued" do
      captured_kw = :unset
      allow(cli.instance_variable_get(:@prompt)).to receive(:ask) do |_prompt, **kw|
        captured_kw = kw
        "typed live"
      end

      expect(cli.ask("Anything?")).to eq("typed live")
      expect(captured_kw).to eq({}) # no prefill — the user types fresh
    end
  end

  describe "approval menu (#approval_choice)" do
    it "does NOT auto-fill a queued line into a destructive grant (Symptom B)" do
      queue.push("yes do it")
      # Stub the picker so no real $stdin is read; capture that NO prefill reached it.
      menu = instance_double(TTY::Prompt)
      allow(menu).to receive(:select).and_return(:once)
      cli.instance_variable_set(:@approval_prompt, menu)

      choice = cli.send(:approval_menu, "approve?", [["Approve once", :once], ["Deny once", :no]])

      expect(choice).to eq(:once)
      expect(queue.shift).to eq("yes do it") # the queued line stays queued, never an approval
    end
  end
end
