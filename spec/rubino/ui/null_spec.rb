# frozen_string_literal: true

RSpec.describe Rubino::UI::Null do
  subject(:ui) { described_class.new }

  describe "message capture" do
    it "captures info messages" do
      ui.info("hello")
      expect(ui.messages.last).to eq({ level: :info, message: "hello" })
    end

    it "captures error messages" do
      ui.error("oops")
      expect(ui.messages.last).to eq({ level: :error, message: "oops" })
    end

    it "captures stream chunks" do
      ui.stream(type: :content, text: "chunk1", message_id: 0)
      ui.stream(type: :content, text: "chunk2", message_id: 0)
      expect(ui.messages.size).to eq(2)
    end

    # Headless FAIL-CLOSED (#260): the Null adapter drives the one-shot /
    # scripted path, where there is no human to ask — so it declines every
    # approval rather than auto-running a write/shell command.
    it "fails closed (returns false) for confirm" do
      expect(ui.confirm("proceed?")).to be false
    end

    it "reports it is not interactive" do
      expect(ui.interactive?).to be false
    end

    it "latches a blocked approval so the one-shot CLI can exit non-zero" do
      expect(ui.approval_blocked?).to be false
      ui.tool_blocked("blocked: shell needs approval but no interactive session")
      expect(ui.approval_blocked?).to be true
      expect(ui.messages).to include(hash_including(level: :tool_blocked))
    end

    it "returns nil for ask" do
      expect(ui.ask("name?")).to be_nil
    end
  end

  describe "#reset!" do
    it "clears all captured messages" do
      ui.info("first")
      ui.error("second")
      ui.reset!
      expect(ui.messages).to be_empty
    end
  end
end
