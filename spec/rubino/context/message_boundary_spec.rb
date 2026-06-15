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

  # #415c (Hermes _ensure_last_user_message_in_tail): the most recent user
  # message must always land in the protected tail. If it falls in the
  # compressed middle, SUMMARY_PREFIX makes the next model treat it as
  # reference-only and the user's latest request silently disappears.
  describe "last-user-message-in-tail guard" do
    def role_seq(roles)
      roles.each_with_index.map do |role, i|
        Rubino::Session::Message.new(session_id: "t", role: role, content: "m#{i}")
      end
    end

    it "grows the tail backward to include a user message that would be in the middle" do
      # protect_first=2, protect_last=3. Last user at index 4 (size 10) would
      # otherwise sit in the middle [2...7]; the tail must grow to cover it.
      roles = %w[system user assistant tool user assistant assistant assistant assistant assistant]
      boundary = described_class.new(messages: role_seq(roles), config: config)

      expect(boundary.tail.map(&:content)).to include("m4")
      expect(boundary.middle.map(&:content)).not_to include("m4")
    end

    it "leaves the window unchanged when the last user message is already in the tail" do
      roles = %w[system assistant assistant assistant assistant assistant assistant assistant user assistant]
      boundary = described_class.new(messages: role_seq(roles), config: config)

      expect(boundary.tail.size).to eq(3) # last user (idx 8) within last 3
      expect(boundary.middle).not_to be_empty
    end

    it "keeps a compressible middle even when the only user message is early" do
      roles = %w[system user assistant assistant assistant assistant assistant assistant assistant assistant]
      boundary = described_class.new(messages: role_seq(roles), config: config)
      # User at idx 1 is inside the protected head -> no tail growth, middle stays.
      expect(boundary.middle).not_to be_empty
    end
  end
end
