# frozen_string_literal: true

require "tmpdir"

# Unit-tests the input-augmentation helper and the vision pre-description step.
# The full Executor#start path requires a live workspace + adapter + recorder;
# covered by integration tests.
RSpec.describe Rubino::Run::Executor do
  subject(:executor) { described_class.new }

  # Minimal real PNG (magic header) on disk so Attachments::Classify sniffs it
  # as a genuine :image — the executor now gates the native/aux-vision egress
  # branch on content, not extension, so these specs need a file that really is
  # an image. The body content is irrelevant; only the magic bytes matter.
  def real_png(dir, name = "img.png")
    path = File.join(dir, name)
    File.binwrite(path, "\x89PNG\r\n\x1A\n".b + ("\x00" * 32).b)
    path
  end

  describe "#augment_input_with_attachments" do
    it "returns the original input when no paths are provided" do
      out = executor.send(:augment_input_with_attachments, "ciao", [])
      expect(out).to eq("ciao")
    end

    it "returns the original input when paths is nil" do
      out = executor.send(:augment_input_with_attachments, "ciao", nil)
      expect(out).to eq("ciao")
    end

    it "pre-pends the header BEFORE the user prompt (anchor for small models)" do
      out = executor.send(:augment_input_with_attachments,
                          "cosa c'è nel img ?",
                          ["/tmp/uploads/abc/cat.webp"])
      expect(out.lines.first).to include("Uploaded files")
      expect(out).to end_with("cosa c'è nel img ?")
    end

    it "renders a typed document preamble for a real PDF (Gap B, not a bare file:)" do
      Dir.mktmpdir do |dir|
        pdf = File.join(dir, "doc.pdf")
        File.binwrite(pdf, "%PDF-1.4\n%\xE2\xE3\xCF\xD3\n1 0 obj<<>>endobj\n")
        real = File.realpath(pdf)
        out = executor.send(:augment_input_with_attachments, "hi", [pdf])
        expect(out).to include("[Attached document: #{real}")
        # With the in-process converter available for PDF (pdf-reader), the
        # document preamble points at read_attachment rather than the markitdown
        # shell-hint; the hint is the nil-fallback when no converter exists.
        expect(out).to include("read_attachment")
        expect(out).not_to include("- file:")
      end
    end

    it "skips an attachment that fails the safety pipeline (non-existent / unsafe)" do
      out = executor.send(:augment_input_with_attachments, "hi", ["/no/such/file.bin"])
      # Header still rendered, but no block for the rejected file.
      expect(out).to include("Uploaded files")
      expect(out).not_to include("/no/such/file.bin")
    end

    it "uses an [Image attached at: …] handle when the image is sent natively" do
      Dir.mktmpdir do |dir|
        png = real_png(dir)
        out = executor.send(:augment_input_with_attachments,
                            "hi", [png],
                            native_image_paths: [png])
        expect(out).to include("[Image attached at: #{png}]")
        # Not pre-described / no tool imperative — the model sees the pixels.
        expect(out).not_to include("vision")
      end
    end

    it "inlines the pre-description for a text-only image when available" do
      Dir.mktmpdir do |dir|
        png = real_png(dir)
        out = executor.send(:augment_input_with_attachments,
                            "descrivi", [png],
                            descriptions: { png => "A red cat on a sofa." })
        expect(out).to include("Here's what it contains:\nA red cat on a sofa.")
        expect(out).to include("call the `vision` tool with file_path: #{png}")
      end
    end

    it "warns (no hidden-tool instruction) when text-only, undescribed, and no aux vision [Gap A]" do
      Dir.mktmpdir do |dir|
        png = real_png(dir)
        out = executor.send(:augment_input_with_attachments, "descrivi", [png])
        expect(out).to include("no multimodal model is configured")
        expect(out).not_to include("Call the `vision` tool")
      end
    end

    it "keeps the on-demand `vision` imperative when an aux vision model IS configured" do
      cfg = Marshal.load(Marshal.dump(Rubino.configuration))
      allow(cfg).to receive(:auxiliary_vision_config).and_return("model" => "auto-vision")
      allow(Rubino).to receive(:configuration).and_return(cfg)
      Dir.mktmpdir do |dir|
        png = real_png(dir)
        out = executor.send(:augment_input_with_attachments, "descrivi", [png])
        expect(out).to include("Call the `vision` tool with file_path: #{png}")
        expect(out).to match(%r{do not use shell/ls}i)
      end
    end

    it "substitutes a default question when the user text is empty and an image is attached" do
      Dir.mktmpdir do |dir|
        png = real_png(dir)
        out = executor.send(:augment_input_with_attachments, "", [png],
                            descriptions: { png => "x" })
        expect(out).to end_with("What do you see in this image?")
      end
    end

    it "preserves the original input verbatim" do
      Dir.mktmpdir do |dir|
        txt = File.join(dir, "x.txt")
        File.write(txt, "hello")
        out = executor.send(:augment_input_with_attachments,
                            "line1\nline2", [txt])
        expect(out).to include("line1\nline2")
      end
    end

    # Egress MIME-spoof guard: a file NAMED .png that is really a ZIP must not
    # be shipped to the native vision model NOR to the external auxiliary vision
    # model on extension alone. Magic wins -> it is classified :archive and gets
    # the archive preamble instead.
    it "does NOT route a .png-named ZIP to native vision (magic wins -> archive preamble)" do
      Dir.mktmpdir do |dir|
        spoof = File.join(dir, "evil.png")
        File.binwrite(spoof, "PK\x03\x04".b + ("\x00" * 64).b) # ZIP local-file-header magic
        real = File.realpath(spoof)
        # Even when offered for native ingestion, it must be demoted.
        out = executor.send(:augment_input_with_attachments, "hi", [spoof],
                            native_image_paths: [spoof])
        expect(out).to include("[Attached archive: #{real}")
        expect(out).not_to include("[Image attached at:")
        expect(out).not_to include("`vision` tool")
      end
    end

    it "does NOT egress a .png-named ZIP to the aux vision model (demoted to archive)" do
      cfg = Marshal.load(Marshal.dump(Rubino.configuration))
      allow(cfg).to receive(:auxiliary_vision_config).and_return("model" => "auto-vision")
      allow(Rubino).to receive(:configuration).and_return(cfg)
      Dir.mktmpdir do |dir|
        spoof = File.join(dir, "evil.png")
        File.binwrite(spoof, "PK\x03\x04".b + ("\x00" * 64).b)
        real = File.realpath(spoof)
        # No native_image_paths and aux configured: the old code would emit the
        # "call the `vision` tool" egress imperative on extension alone.
        out = executor.send(:augment_input_with_attachments, "hi", [spoof])
        expect(out).to include("[Attached archive: #{real}")
        expect(out).not_to include("`vision` tool")
      end
    end
  end

  describe "#preprocess_images_with_vision" do
    let(:recorder) { double("recorder", emit: nil) }

    # Mirrors the convention in executor_native_image_paths_spec: dup the
    # config and stub the one accessor we care about.
    def stub_aux_vision(model)
      cfg = Marshal.load(Marshal.dump(Rubino.configuration))
      allow(cfg).to receive(:auxiliary_vision_config).and_return(model ? { "model" => model } : {})
      allow(Rubino).to receive(:configuration).and_return(cfg)
    end

    it "describes only text-only images (skips native ones and non-images)" do
      stub_aux_vision("auto-vision")
      describer = ->(path) { "desc for #{path}" }
      exec = described_class.new(vision_describer: describer)
      out = exec.send(:preprocess_images_with_vision,
                      ["/a/img.png", "/b/native.jpg", "/c/doc.pdf"],
                      ["/b/native.jpg"], recorder)
      expect(out).to eq("/a/img.png" => "desc for /a/img.png")
    end

    it "drops images whose description errored and emits a failure event" do
      stub_aux_vision("auto-vision")
      describer = ->(_path) { "Error calling vision model: boom" }
      exec = described_class.new(vision_describer: describer)
      expect(recorder).to receive(:emit).with("run.vision_preprocess_failed", hash_including(:path, :error))
      out = exec.send(:preprocess_images_with_vision, ["/a/img.png"], [], recorder)
      expect(out).to eq({})
    end

    it "is a no-op when no aux vision model is configured" do
      stub_aux_vision(nil)
      describer = ->(_path) { raise "should not be called" }
      exec = described_class.new(vision_describer: describer)
      out = exec.send(:preprocess_images_with_vision, ["/a/img.png"], [], recorder)
      expect(out).to eq({})
    end
  end
end
