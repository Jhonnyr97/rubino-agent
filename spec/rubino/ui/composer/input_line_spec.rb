# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rubino::UI::Composer::InputLine do
  subject(:line) { described_class.new }

  it "starts empty with the cursor at 0" do
    expect(line.text).to eq("")
    expect(line.cursor).to eq(0)
    expect(line).to be_empty
  end

  describe "#insert" do
    it "inserts at the cursor and advances past it" do
      line.insert("abc")
      expect(line.text).to eq("abc")
      expect(line.cursor).to eq(3)
    end

    it "inserts mid-buffer at the cursor (codepoint-correct with multibyte)" do
      line.insert("aé中")
      line.move_to(1)
      line.insert("X")
      expect(line.text).to eq("aXé中")
      expect(line.cursor).to eq(2)
    end
  end

  describe "#delete_back" do
    it "removes the char before the cursor" do
      line.insert("abc").delete_back
      expect(line.text).to eq("ab")
      expect(line.cursor).to eq(2)
    end

    it "is a no-op at column 0" do
      line.insert("ab").move_to(0).delete_back
      expect(line.text).to eq("ab")
      expect(line.cursor).to eq(0)
    end

    it "deletes a whole multibyte glyph, not a byte" do
      line.insert("aé中").delete_back
      expect(line.text).to eq("aé")
    end
  end

  describe "#delete_span (placeholder whole-token delete)" do
    it "removes the span and parks the cursor at its start" do
      line.insert("x[Pasted #1]y").delete_span(1, 11)
      expect(line.text).to eq("xy")
      expect(line.cursor).to eq(1)
    end
  end

  describe "#delete_forward" do
    it "removes the char at the cursor" do
      line.insert("abc").move_to(1).delete_forward
      expect(line.text).to eq("ac")
      expect(line.cursor).to eq(1)
    end

    it "is a no-op at the end" do
      line.insert("abc").delete_forward
      expect(line.text).to eq("abc")
    end
  end

  describe "#kill_to_end" do
    it "deletes from the cursor to the end" do
      line.insert("hello").move_to(2).kill_to_end
      expect(line.text).to eq("he")
    end
  end

  describe "#clear / #take" do
    it "clear empties the line and resets the cursor" do
      line.insert("abc").clear
      expect(line.text).to eq("")
      expect(line.cursor).to eq(0)
    end

    it "take returns the text and resets to empty" do
      line.insert("submit me")
      expect(line.take).to eq("submit me")
      expect(line.text).to eq("")
      expect(line.cursor).to eq(0)
    end
  end

  describe "#replace" do
    it "replaces the whole line and parks the cursor at the end" do
      line.insert("old").replace("new line")
      expect(line.text).to eq("new line")
      expect(line.cursor).to eq(8)
    end
  end

  describe "cursor movement" do
    it "move_by clamps to the buffer" do
      line.insert("abc")
      line.move_by(-10)
      expect(line.cursor).to eq(0)
      line.move_by(100)
      expect(line.cursor).to eq(3)
    end

    it "move_to clamps to the buffer" do
      line.insert("abc").move_to(99)
      expect(line.cursor).to eq(3)
    end

    it "word_left lands at the start of the previous word" do
      line.insert("foo bar baz") # cursor at end (11)
      line.word_left
      expect(line.cursor).to eq(8) # start of "baz"
      line.word_left
      expect(line.cursor).to eq(4) # start of "bar"
    end

    it "word_right lands at the start of the next word" do
      line.insert("foo bar baz").move_to(0).word_right
      expect(line.cursor).to eq(4) # start of "bar"
    end
  end
end
