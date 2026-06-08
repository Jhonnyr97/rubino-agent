# frozen_string_literal: true

RSpec.describe Rubino::Context::MessageBoundary do
  let(:config) { test_configuration("compression" => { "protect_first_n" => 2, "protect_last_n" => 3 }) }

  def make_messages(count)
    count.times.map do |i|
      Rubino::Session::Message.new(
        session_id: "test",
        role: "user",
        content: "message #{i}"
      )
    end
  end

  describe "#head" do
    it "returns the first N protected messages" do
      messages = make_messages(10)
      boundary = described_class.new(messages: messages, config: config)
      expect(boundary.head.size).to eq(2)
      expect(boundary.head.first.content).to eq("message 0")
    end
  end

  describe "#tail" do
    it "returns the last N protected messages" do
      messages = make_messages(10)
      boundary = described_class.new(messages: messages, config: config)
      expect(boundary.tail.size).to eq(3)
      expect(boundary.tail.last.content).to eq("message 9")
    end
  end

  describe "#middle" do
    it "returns the compressible messages between head and tail" do
      messages = make_messages(10)
      boundary = described_class.new(messages: messages, config: config)
      expect(boundary.middle.size).to eq(5) # 10 - 2 - 3 = 5
    end

    it "returns empty when messages are too few" do
      messages = make_messages(4) # 4 < 2 + 3
      boundary = described_class.new(messages: messages, config: config)
      expect(boundary.middle).to be_empty
    end
  end
end
