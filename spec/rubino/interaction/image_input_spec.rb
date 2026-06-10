# frozen_string_literal: true

require "tmpdir"

RSpec.describe Rubino::Interaction::ImageInput do
  around do |ex|
    Dir.mktmpdir do |dir|
      @dir = dir
      ex.run
    end
  end

  # Fixtures carry REAL magic bytes for their extension: the attachment gate
  # verifies image signatures (#158), so an extension alone no longer passes.
  def make(name)
    path = File.join(@dir, name)
    sig = { ".png" => "\x89PNG\r\n\x1a\n", ".jpg" => "\xFF\xD8\xFF", ".jpeg" => "\xFF\xD8\xFF",
            ".gif" => "GIF89a", ".webp" => "RIFF\x20\x00\x00\x00WEBPVP8 ", ".bmp" => "BM" }[File.extname(name)]
    File.binwrite(path, "#{sig}x".b)
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

  # Regression #98: CLI image candidates must pass the SAME secure-by-default
  # attachment gate as the server/run path (Attachments::Classify + Policy) —
  # oversize and content-spoofed files used to be shipped to the provider and
  # retried 5x on the permanent rejection.
  describe ".parse — attachment policy gate (#98)" do
    # PK\x03\x04 = ZIP local-file-header magic: an image-extension file whose
    # content is NOT an image (the MIME-spoof case).
    def make_spoof(name)
      path = File.join(@dir, name)
      File.binwrite(path, "PK\x03\x04\x14\x00\x00\x00\x08\x00#{" " * 50}")
      path
    end

    def make_png(name, padding: 64)
      path = File.join(@dir, name)
      File.binwrite(path, "\x89PNG\r\n\x1a\n#{" " * padding}")
      path
    end

    it "rejects (and consumes) an image-extension file whose content is not an image" do
      spoof = make_spoof("fake.png")

      result = described_class.parse("look @#{spoof}")

      expect(result.image_paths).to be_empty
      expect(result.text).to eq("look")
      expect(result.rejected.size).to eq(1)
      expect(result.rejected.first[:path]).to eq(spoof)
      expect(result.rejected.first[:reason]).to include("not a valid image (content is application/zip)")
    end

    it "rejects a TEXT file renamed .png — Marcel's extension fallback must not win (#158)" do
      spoof = File.join(@dir, "fake.png")
      File.write(spoof, "this is not an image\n")

      result = described_class.parse("describe @#{spoof}")

      expect(result.image_paths).to be_empty
      expect(result.text).to eq("describe")
      expect(result.rejected.first[:reason]).to eq("not a valid image (content is text/plain)")
    end

    it "rejects an image exceeding max_file_bytes with a human-readable reason" do
      big = make_png("big.png")
      allow(Rubino::Attachments::Policy).to receive(:max_file_bytes).and_return(16)

      result = described_class.parse("see @#{big}")

      expect(result.image_paths).to be_empty
      expect(result.rejected.first[:reason]).to match(/exceeds the \d+ MB attachment limit/)
    end

    it "rejects an image when :image is not in allow_kinds" do
      img = make_png("ok.png")
      allow(Rubino::Attachments::Policy).to receive(:allow_kind?).with(:image).and_return(false)

      result = described_class.parse("@#{img}")

      expect(result.image_paths).to be_empty
      expect(result.rejected.first[:reason]).to include("disabled by policy")
    end

    it "attaches a real image that passes the policy, with no rejections" do
      img = make_png("real.png")

      result = described_class.parse("@#{img}")

      expect(result.image_paths).to eq([img])
      expect(result.rejected).to be_empty
    end
  end

  describe ".attachment_error" do
    it "returns nil for a safe real image" do
      img = File.join(@dir, "fine.png")
      File.binwrite(img, "\x89PNG\r\n\x1a\n#{" " * 64}")

      expect(described_class.attachment_error(img)).to be_nil
    end

    it "returns the classifier's reason for an unsafe file (e.g. a symlink)" do
      target = make("target.png")
      link = File.join(@dir, "link.png")
      File.symlink(target, link)

      expect(described_class.attachment_error(link)).to include("not a regular file")
    end
  end
end
