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

    it "returns true for confirm" do
      expect(ui.confirm("proceed?")).to be true
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
