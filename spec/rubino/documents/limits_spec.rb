# frozen_string_literal: true

require "spec_helper"
require "zip"
require "tmpdir"
require "benchmark"

# Decompression-bomb / runaway-conversion caps for the in-process document
# converters (S4-1). These specs FAIL on the pre-fix code: there the converter
# pipeline has no timeout, no element/row/page cap, no decompressed-bytes
# ceiling and no cancellation check, so a 100 KB .docx (1M paragraphs / 34 MB
# XML) drives ~100 s / 1.4 GB before the output cap throws the result away.
# Here we assert each cap trips, bounds time, and degrades to the shell-hint
# path (to_markdown -> nil), and that the cancel_token is honored mid-flight.
RSpec.describe Rubino::Documents::Limits do
  # A small cap so the bomb specs run fast and deterministically without
  # building a multi-megabyte fixture: the DEFENSE is the same, we just lower
  # the numbers. The pre-fix code has NO such cap at all, so these still fail
  # there (the conversion runs to completion / OOM instead of bailing).
  def tight_budget(cancel_token: nil)
    Rubino::Documents::Limits::Budget.new(
      max_elements: 100,
      max_decompressed_bytes: 50_000,
      wall_clock_seconds: 0.5,
      cancel_token: cancel_token
    )
  end

  describe Rubino::Documents::Limits::Budget do
    it "raises CapExceeded once the element ceiling is crossed" do
      b = described_class.new(max_elements: 3, max_decompressed_bytes: 1 << 30,
                              wall_clock_seconds: 60)
      3.times { b.tick }
      expect { b.tick }.to raise_error(Rubino::Documents::CapExceeded, /element count cap/)
    end

    it "raises CapExceeded once the decompressed-bytes ceiling is crossed" do
      b = described_class.new(max_elements: 1 << 30, max_decompressed_bytes: 1000,
                              wall_clock_seconds: 60)
      b.tick(bytes: 999)
      expect { b.tick(bytes: 2) }.to raise_error(Rubino::Documents::CapExceeded, /decompressed size cap/)
    end

    it "raises CapExceeded once the wall-clock budget is spent" do
      b = described_class.new(max_elements: 1 << 30, max_decompressed_bytes: 1 << 30,
                              wall_clock_seconds: 0.0)
      # The clock is sampled every TICK_INTERVAL elements; cross that boundary.
      expect do
        (Rubino::Documents::Limits::TICK_INTERVAL + 1).times { b.tick }
      end.to raise_error(Rubino::Documents::CapExceeded, /wall-clock budget/)
    end

    it "honors the cancel_token (raises Interrupted, NOT CapExceeded)" do
      token = Rubino::Interaction::CancelToken.new
      b = described_class.new(max_elements: 1 << 30, max_decompressed_bytes: 1 << 30,
                              wall_clock_seconds: 60, cancel_token: token)
      b.tick
      token.cancel!
      expect { b.tick }.to raise_error(Rubino::Interrupted)
    end

    it "the null_budget never trips on a sane document" do
      b = Rubino::Documents::Limits.null_budget
      expect { 100_000.times { b.tick(bytes: 10) } }.not_to raise_error
    end
  end

  describe ".guard_zip! (pre-open decompression-bomb defense)" do
    # The decisive cost of an OOXML bomb is paid at gem-open, when the whole
    # decompressed XML is read and the full DOM built -- BEFORE any paragraph is
    # yielded. The central directory carries the uncompressed size, so we bail
    # before inflating. Build a tiny .zip whose ONE entry decompresses huge.
    def bomb_zip(entry_name, uncompressed_bytes)
      path = File.join(Dir.tmpdir, "rubino_bomb_#{rand(1 << 32)}.zip")
      Zip::File.open(path, create: true) do |z|
        z.get_output_stream(entry_name) { |o| o.write("A" * uncompressed_bytes) }
      end
      path
    end

    it "raises CapExceeded when the summed uncompressed entry size exceeds the cap" do
      path = bomb_zip("word/document.xml", 200_000)
      budget = Rubino::Documents::Limits::Budget.new(max_elements: 1 << 30,
                                                     max_decompressed_bytes: 50_000,
                                                     wall_clock_seconds: 60)
      expect do
        described_class.guard_zip!(path, budget, ["word/document*.xml"])
      end.to raise_error(Rubino::Documents::CapExceeded, /zip size cap/)
    ensure
      FileUtils.rm_f(path) if path
    end

    it "stays SILENT (fast, decompresses nothing) for an entry under the cap" do
      path = bomb_zip("word/document.xml", 1_000)
      budget = Rubino::Documents::Limits::Budget.new(max_elements: 1 << 30,
                                                     max_decompressed_bytes: 50_000,
                                                     wall_clock_seconds: 60)
      expect { described_class.guard_zip!(path, budget, ["word/document*.xml"]) }.not_to raise_error
    ensure
      FileUtils.rm_f(path) if path
    end

    it "ignores entries outside the matched globs" do
      path = bomb_zip("docProps/thumbnail.bin", 5_000_000)
      budget = Rubino::Documents::Limits::Budget.new(max_elements: 1 << 30,
                                                     max_decompressed_bytes: 50_000,
                                                     wall_clock_seconds: 60)
      # The huge entry is not a body XML, so it is not summed -> no bail.
      expect { described_class.guard_zip!(path, budget, ["word/document*.xml"]) }.not_to raise_error
    ensure
      FileUtils.rm_f(path) if path
    end
  end

  describe "end-to-end: a paragraph-bomb .docx bails to the shell-hint path", if: docx_available? do
    # ~1M <w:p> in a tiny on-disk file: highly compressible, ~34 MB inflated.
    # Pre-fix: ~100 s / 1.4 GB. Post-fix: guard_zip! bails at open() in <1 s.
    def build_para_bomb(path, paras)
      doc = <<~XML
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
          <w:body>#{"<w:p><w:pPr/><w:r><w:t>x</w:t></w:r></w:p>" * paras}</w:body>
        </w:document>
      XML
      content_types = <<~XML
        <?xml version="1.0"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
          <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
          <Default Extension="xml" ContentType="application/xml"/>
          <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
        </Types>
      XML
      rels = <<~XML
        <?xml version="1.0"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
          <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
        </Relationships>
      XML
      files = {
        "[Content_Types].xml" => content_types,
        "_rels/.rels" => rels,
        "word/document.xml" => doc
      }
      FileUtils.rm_f(path)
      Zip::File.open(path, create: true) do |z|
        files.each { |name, content| z.get_output_stream(name) { |f| f.write(content) } }
      end
    end

    it "returns nil (-> shell-hint) within the wall-clock budget, not OOM/hang" do
      path = File.join(Dir.tmpdir, "rubino_bomb_#{rand(1 << 32)}.docx")
      build_para_bomb(path, 1_000_000)
      expect(File.size(path)).to be < 2_000_000 # tiny on disk -- the bomb

      result = nil
      elapsed = Benchmark.realtime do
        result = described_class_to_markdown(path)
      end

      expect(result).to be_nil               # degraded to the shell-hint path
      expect(elapsed).to be < 10             # bounded -- NOT ~100 s
    ensure
      FileUtils.rm_f(path) if path
    end

    # Helper: the public conversion entry point with a tight budget injected via
    # config so the cap trips on a small fixture in CI without a 34 MB inflate.
    def described_class_to_markdown(path)
      with_tight_convert_caps { Rubino::Documents.to_markdown(path, mime: nil) }
    end
  end

  describe "a NORMAL small .docx still converts correctly", if: docx_available? do
    let(:fixtures) { File.expand_path("../../fixtures/documents", __dir__) }

    it "converts the committed sample.docx with caps in force" do
      md = with_tight_convert_caps do
        Rubino::Documents.to_markdown(File.join(fixtures, "sample.docx"))
      end
      expect(md).not_to be_nil
      expect(md).to include("Project Plan")
    end
  end

  describe "a long conversion is interruptible (cancel_token honored)", if: docx_available? do
    let(:fixtures) { File.expand_path("../../fixtures/documents", __dir__) }

    it "raises Interrupted out of to_markdown when the token is flipped" do
      token = Rubino::Interaction::CancelToken.new
      token.cancel! # already cancelled: the first per-element tick must bail
      expect do
        Rubino::Documents.to_markdown(File.join(fixtures, "sample.docx"), cancel_token: token)
      end.to raise_error(Rubino::Interrupted)
    end
  end

  # Lowers the converter caps via config (the same `attachments.policy` surface
  # Policy reads from) so a small fixture trips them. The DEFENSE under test is
  # identical at the default caps; this just keeps the bomb fixtures CI-cheap.
  def with_tight_convert_caps
    cfg = Marshal.load(Marshal.dump(Rubino.configuration))
    allow(cfg).to receive(:dig).and_call_original
    allow(cfg).to receive(:dig).with("attachments", "policy").and_return(
      "convert_max_elements" => 1000,
      "convert_max_decompressed_bytes" => 50_000,
      "convert_wall_clock_seconds" => 5.0
    )
    allow(Rubino).to receive(:configuration).and_return(cfg)
    yield
  end
end
