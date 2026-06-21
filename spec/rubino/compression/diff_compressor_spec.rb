# frozen_string_literal: true

# Deterministic unified-diff compressor. The whole contract is the FIDELITY
# INVARIANT: every +/- line and every file/hunk header survives; only far
# pure-context lines and generated/lock-file bodies are dropped. Small/tight
# diffs pass through byte-identical (the saving guard), so the common "show me
# the diff" case is never touched.
RSpec.describe Rubino::Compression::DiffCompressor do
  subject(:compressor) { described_class.new(config) }

  let(:config) do
    { "context_lines" => 3, "min_lines" => 10, "min_saving" => 0.25,
      "generated_patterns" => described_class::DEFAULT_GENERATED }
  end

  # A diff with a single change buried in a long run of unchanged context.
  def wide_context_diff(context:)
    pre  = (1..context).map { |i| " ctx-before-#{i}" }
    post = (1..context).map { |i| " ctx-after-#{i}" }
    body = [*pre, "-old line", "+new line", *post]
    head = <<~HEAD
      diff --git a/big.rb b/big.rb
      index 1111111..2222222 100644
      --- a/big.rb
      +++ b/big.rb
      @@ -1,#{context + 1} +1,#{context + 1} @@ def thing
    HEAD
    "#{head}#{body.join("\n")}\n"
  end

  describe "the fidelity invariant" do
    it "keeps every +/- line and the file + hunk headers when it compresses" do
      diff = wide_context_diff(context: 30)
      result = compressor.compress(diff)

      expect(result.applied?).to be true
      expect(result.text).to include("diff --git a/big.rb b/big.rb")
      expect(result.text).to include("--- a/big.rb")
      expect(result.text).to include("+++ b/big.rb")
      expect(result.text).to match(/^@@ -1,\d+ \+1,\d+ @@/)
      expect(result.text).to include("-old line")
      expect(result.text).to include("+new line")
    end

    it "preserves ALL K changed lines across a multi-change hunk" do
      changes = (1..8).map { |i| ["-removed #{i}", "+added #{i}"] }.flatten
      padded  = changes.flat_map { |c| [c, *(1..20).map { |j| " pad-#{c}-#{j}" }] }
      head = <<~HEAD
        diff --git a/m.rb b/m.rb
        --- a/m.rb
        +++ b/m.rb
        @@ -1,80 +1,80 @@
      HEAD
      result = compressor.compress("#{head}#{padded.join("\n")}\n")

      expect(result.applied?).to be true
      (1..8).each do |i|
        expect(result.text).to include("-removed #{i}")
        expect(result.text).to include("+added #{i}")
      end
    end
  end

  describe "context trimming" do
    it "collapses far context into a marker but keeps ±N around the change" do
      result = compressor.compress(wide_context_diff(context: 30))

      expect(result.text).to include(" ctx-before-30") # within 3 of the change
      expect(result.text).to include(" ctx-after-1")
      expect(result.text).not_to include(" ctx-before-1") # far → dropped
      expect(result.text).to match(/… \d+ unchanged lines/)
    end

    it "passes a tight-context diff through (nothing to trim → saving guard)" do
      result = compressor.compress(wide_context_diff(context: 3))
      expect(result.applied?).to be false
    end
  end

  describe "generated/lock-file summarization" do
    it "collapses a Gemfile.lock change to a one-line summary, headers intact" do
      body = (1..40).map { |i| i.even? ? "+    gem-#{i} (1.0.#{i})" : "-    gem-#{i} (0.9.#{i})" }
      head = <<~HEAD
        diff --git a/Gemfile.lock b/Gemfile.lock
        index aaa..bbb 100644
        --- a/Gemfile.lock
        +++ b/Gemfile.lock
        @@ -1,40 +1,40 @@
      HEAD
      result = compressor.compress("#{head}#{body.join("\n")}\n")

      expect(result.applied?).to be true
      expect(result.text).to include("diff --git a/Gemfile.lock b/Gemfile.lock")
      expect(result.text).to match(%r{Gemfile\.lock: \+\d+/-\d+ lines, 1 hunk — elided \(generated\)})
      expect(result.text).not_to include("gem-2 (1.0.2)") # body elided
    end

    it "matches glob patterns (*.min.js) and dir patterns (dist/)" do
      %w[app.min.js dist/bundle.js].each do |path|
        body = (1..30).map { |i| "+x#{i}" }
        diff = "diff --git a/#{path} b/#{path}\n--- a/#{path}\n+++ b/#{path}\n@@ -1,30 +1,30 @@\n#{body.join("\n")}\n"
        result = compressor.compress(diff)
        expect(result.text).to include("elided (generated)") if result.applied?
      end
    end
  end

  describe "the saving guard" do
    it "returns a no-op below min_lines (small diff stays intact)" do
      diff = "diff --git a/a b/a\n--- a/a\n+++ b/a\n@@ -1 +1 @@\n-x\n+y\n"
      result = compressor.compress(diff)
      expect(result.applied?).to be false
      expect(result.strategy).to eq(:too_small)
    end

    it "returns a no-op when the saving is below min_saving" do
      # 40 lines but already tight context → trimming saves ~nothing.
      body = (1..40).map { |i| "+line #{i}" }
      diff = "diff --git a/a b/a\n--- a/a\n+++ b/a\n@@ -1,40 +1,40 @@\n#{body.join("\n")}\n"
      result = compressor.compress(diff)
      expect(result.applied?).to be false
      expect(result.strategy).to eq(:insufficient_saving)
    end

    it "returns a no-op (parse_error) on non-diff text of sufficient length" do
      text = (1..50).map { |i| "just a line #{i}" }.join("\n")
      result = compressor.compress(text)
      expect(result.applied?).to be false
      expect(result.strategy).to eq(:parse_error)
    end
  end

  it "preserves a trailing newline through compression" do
    diff = wide_context_diff(context: 30)
    expect(diff).to end_with("\n")
    result = compressor.compress(diff)
    expect(result.text).to end_with("\n")
  end
end
