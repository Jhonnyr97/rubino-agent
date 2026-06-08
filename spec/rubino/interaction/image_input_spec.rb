# frozen_string_literal: true

require "tmpdir"

RSpec.describe Rubino::Interaction::ImageInput do
  around do |ex|
    Dir.mktmpdir do |dir|
      @dir = dir
      ex.run
    end
  end

  def make(name)
    path = File.join(@dir, name)
    File.binwrite(path, "x")
    path
  end

  describe ".parse — @image references" do
    it "attaches an @image.png to image_paths and removes it from the text" do
      img = make("foo.png")

      result = described_class.parse("look at @#{img} please")

      expect(result.image_paths).to eq([img])
      expect(result.text).to eq("look at please")
      expect(result.images?).to be(true)
    end

    it "leaves a non-image @file in the text (current behaviour, no attach)" do
      doc = make("notes.md")

      result = described_class.parse("read @#{doc} now")

      expect(result.image_paths).to be_empty
      expect(result.text).to include("@#{doc}")
    end

    it "supports multiple images in one line" do
      a = make("a.png")
      b = make("b.jpg")

      result = described_class.parse("@#{a} vs @#{b}")

      expect(result.image_paths).to contain_exactly(a, b)
    end

    it "recognises every supported extension" do
      paths = %w[a.png b.jpg c.jpeg d.gif e.webp f.bmp].map { |n| make(n) }
      line  = paths.map { |p| "@#{p}" }.join(" ")

      expect(described_class.parse(line).image_paths).to match_array(paths)
    end
  end

  describe ".parse — dropped / pasted paths" do
    it "attaches a bare absolute image path" do
      img = make("dropped.png")

      result = described_class.parse("describe #{img}")

      expect(result.image_paths).to eq([img])
      expect(result.text).to eq("describe")
    end

    it "attaches a double-quoted path (terminal drag-drop)" do
      img = make("quoted.png")

      result = described_class.parse(%(check "#{img}" out))

      expect(result.image_paths).to eq([img])
    end

    it "attaches a single-quoted path" do
      img = make("single.png")

      result = described_class.parse("see '#{img}'")

      expect(result.image_paths).to eq([img])
    end

    it "handles a backslash-escaped space in a dropped path" do
      img = make("my pic.png")
      escaped = img.gsub(" ", "\\ ")

      result = described_class.parse("look #{escaped}")

      expect(result.image_paths).to eq([img])
    end
  end

  describe ".parse — non-attaching cases" do
    it "ignores an image path that does not exist on disk" do
      ghost = File.join(@dir, "missing.png")

      result = described_class.parse("see #{ghost}")

      expect(result.image_paths).to be_empty
      expect(result.text).to include(ghost)
    end

    it "leaves plain text untouched" do
      result = described_class.parse("just a normal sentence")

      expect(result.image_paths).to be_empty
      expect(result.text).to eq("just a normal sentence")
    end
  end

  describe ".parse — accumulation & dedup" do
    it "carries forward existing attachments" do
      old = make("old.png")
      new = make("new.png")

      result = described_class.parse("@#{new}", existing: [old])

      expect(result.image_paths).to eq([old, new])
    end

    it "de-duplicates the same image referenced twice" do
      img = make("dup.png")

      expect(described_class.parse("@#{img} @#{img}").image_paths).to eq([img])
    end
  end
end
