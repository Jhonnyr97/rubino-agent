# frozen_string_literal: true

require "json"

# Deterministic JSON compressor. The contract: an ARRAY of uniform objects folds
# LOSSLESSLY to a schema header + compact rows; a large array that doesn't save
# enough falls back to LOSSY row selection where error-bearing rows ALWAYS
# survive; a single large object elides only big string values (never drops a
# key); small JSON and non-JSON pass through (noop). Modelled on headroom's
# SmartCrusher.
RSpec.describe Rubino::Compression::JsonCompressor do
  subject(:compressor) { described_class.new(config) }

  let(:config) do
    { "min_items" => 8, "min_lines" => 40, "min_saving" => 0.25,
      "outlier_sigma" => 3.0, "max_string_chars" => 100 }
  end

  # A large uniform array (kubectl-pods-ish): same keys on every row.
  def uniform_array(count, with_error_at: nil)
    arr = (0...count).map do |i|
      { "name" => "pod-#{i}", "namespace" => "default", "phase" => "Running",
        "restarts" => 0, "node" => "node-a" }
    end
    arr[with_error_at]["phase"] = "CrashLoopBackOff" if with_error_at
    arr[with_error_at]["error"] = "back-off restarting failed container" if with_error_at
    JSON.pretty_generate(arr)
  end

  describe "lossless schema-fold (array of uniform objects)" do
    it "compresses, emitting the keys once and one row per item" do
      result = compressor.compress(uniform_array(50))

      expect(result.applied?).to be true
      expect(result.strategy).to eq(:json)
      # keys are emitted ONCE in a stable sorted order
      expect(result.text).to include("keys: name | namespace | node | phase | restarts")
      # 50 data rows + 1 header line
      expect(result.text.lines.length).to eq(51)
      # the repeated key name "namespace" appears ONCE (header), not per row
      expect(result.text.scan("namespace").length).to eq(1)
      expect(result.ratio).to be >= 0.25
    end

    it "is lossless: every row's values survive (sorted-key order)" do
      result = compressor.compress(uniform_array(50))
      data_rows = result.text.lines[1..]
      # columns in sorted-key order: name | namespace | node | phase | restarts
      expect(data_rows.first).to start_with("pod-0 | default | node-a | Running | 0")
      expect(data_rows.last).to start_with("pod-49 | default | node-a | Running | 0")
    end
  end

  describe "the saving guard" do
    it "passes through a SMALL JSON byte-identical (below the size gate)" do
      small = JSON.pretty_generate([{ "a" => 1 }, { "a" => 2 }])
      result = compressor.compress(small)

      expect(result.applied?).to be false
      expect(result.strategy).to eq(:too_small)
    end

    it "does not apply when the fold saves less than min_saving" do
      # 8 rows of a single tiny key — the schema header costs as much as it saves.
      tight = JSON.generate((0...8).map { |i| { "x" => i } })
      result = compressor.compress(tight)
      expect(result.applied?).to be false
    end
  end

  describe "the lossy fallback (fidelity)" do
    # Force lossy: a high min_saving the lossless fold can't reach, but the
    # array is large (≥ 2× min_items) so row-selection kicks in.
    let(:config) do
      { "min_items" => 4, "min_lines" => 5, "min_saving" => 0.6,
        "outlier_sigma" => 3.0, "max_string_chars" => 100 }
    end

    it "ALWAYS keeps error-bearing items and elides the rest behind a sentinel" do
      arr = (0...40).map { |i| { "n" => "row#{i}", "ok" => true } }
      arr[20] = { "n" => "row20", "ok" => false, "error" => "disk write failed" }
      result = compressor.compress(JSON.generate(arr))

      expect(result.applied?).to be true
      # the error row survives verbatim (its value is in the row)
      expect(result.text).to include("disk write failed")
      # dropped rows collapse to an _elided sentinel carrying a count
      expect(result.text).to match(/\{"_elided":\d+\}/)
      # boundary kept
      expect(result.text).to include("row0 |")
      expect(result.text).to include("row39 |")
    end

    it "keeps a statistical outlier row" do
      arr = (0...40).map { |i| { "name" => "n#{i}", "size" => 10 } }
      arr[7]["size"] = 100_000 # far outlier
      result = compressor.compress(JSON.generate(arr))
      expect(result.text).to include("n7 | 100000")
    end
  end

  describe "single large object" do
    let(:config) do
      { "min_items" => 8, "min_lines" => 5, "min_saving" => 0.25,
        "outlier_sigma" => 3.0, "max_string_chars" => 100 }
    end

    it "elides only large string values and keeps every key" do
      obj = { "id" => 1, "blob" => "x" * 5000, "name" => "keep-me",
              "nested" => { "log" => "y" * 5000 } }
      result = compressor.compress(JSON.pretty_generate(obj))

      expect(result.applied?).to be true
      expect(result.text).to include("<elided 5000 chars>")
      expect(result.text).to include('"name": "keep-me"')
      expect(result.text).to include('"id": 1')
      # both big strings elided
      expect(result.text.scan("<elided 5000 chars>").length).to eq(2)
    end
  end

  describe "non-JSON content" do
    it "returns :not_json so the router falls through" do
      result = compressor.compress("not json at all\njust a log line")
      expect(result.applied?).to be false
      expect(result.strategy).to eq(:not_json)
    end

    it "treats a bare scalar / number as not-json" do
      expect(compressor.compress("42").strategy).to eq(:not_json)
      expect(compressor.compress('"a string"').strategy).to eq(:not_json)
    end

    it "treats a log line that merely starts with { as not-json" do
      result = compressor.compress("{INFO} starting up\nmore log lines")
      expect(result.applied?).to be false
      expect(result.strategy).to eq(:not_json)
    end
  end

  describe "heterogeneous arrays (out of scope)" do
    let(:config) do
      { "min_items" => 4, "min_lines" => 5, "min_saving" => 0.0,
        "outlier_sigma" => 3.0, "max_string_chars" => 100 }
    end

    it "passes through an array of non-objects" do
      result = compressor.compress(JSON.generate([1, 2, 3, 4, 5, 6, 7, 8]))
      expect(result.applied?).to be false
      expect(result.strategy).to eq(:too_small)
    end

    it "passes through an array whose objects have no shared shape" do
      arr = (0...10).map { |i| { "k#{i}" => i } } # every object a different key
      result = compressor.compress(JSON.generate(arr))
      expect(result.applied?).to be false
    end
  end

  describe "errors never break the tool call" do
    it "returns a noop (never raises) on internal failure" do
      allow(JSON).to receive(:pretty_generate).and_raise("boom")
      obj = { "blob" => "x" * 5000 }
      result = compressor.compress(JSON.generate([obj] * 10))
      expect(result.applied?).to be false
    end
  end
end
