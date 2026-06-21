# frozen_string_literal: true

# The single content-routed compression seam. Verifies the router DETECTS the
# content type from the text + the tool's hint and dispatches to the right
# strategy — and, crucially, that diff / grep / short outputs PASS THROUGH
# byte-identical (the safety win), while errors fall back to passthrough.
RSpec.describe Rubino::Compression::ContentRouter do
  subject(:router) { described_class.new(Rubino.configuration) }

  def enable!(code: true, logs: true)
    Rubino.configuration.set("tool_output_compression", "enabled", true)
    if code
      Rubino.configuration.set("tool_output_compression", "code",
                               "strategy" => "skeleton", "min_lines" => 5,
                               "keep_method_body_max_lines" => 2)
    end
    Rubino.configuration.set("tool_output_compression", "diff",
                             "context_lines" => 3, "min_lines" => 10, "min_saving" => 0.25,
                             "generated_patterns" =>
                               Rubino::Compression::DiffCompressor::DEFAULT_GENERATED)
    return unless logs

    Rubino.configuration.set("tool_output_compression", "logs",
                             "enabled" => true, "min_lines" => 10,
                             "max_total_lines" => 100, "max_errors" => 10,
                             "max_warnings" => 5, "max_stack_traces" => 3,
                             "context_lines" => 4)
  end

  # A generic (non-test-runner) command dump: ERROR keyword + lots of INFO noise.
  let(:noisy_log) do
    "#{(1..60).map { |i| "INFO processing item #{i}" }.join("\n")}\nERROR boom happened\nDone."
  end

  let(:ruby_source) do
    body = (1..12).map { |i| "    step#{i} = step#{i - 1} + #{i}" }.join("\n")
    <<~RUBY
      class Calc
        def big_method(step0)
      #{body}
          step12
        end

        def small = 1
      end
    RUBY
  end

  let(:grep_output) do
    "#{(1..12).map { |i| "lib/file#{i}.rb:#{i * 3}:  def method_#{i}" }.join("\n")}\n"
  end

  # A SMALL/tight diff — the common "show me the diff" case the saving guard
  # must let through byte-identical.
  let(:diff_output) do
    <<~DIFF
      diff --git a/x.rb b/x.rb
      @@ -1,3 +1,3 @@
      -old line
      +new line
       context
    DIFF
  end

  # A LARGE diff: one change buried in a long run of unchanged context — the
  # DiffCompressor trims the far context while keeping the +/- lines + headers.
  let(:wide_diff) do
    ctx_before = (1..30).map { |i| " ctx-before-#{i}" }
    ctx_after  = (1..30).map { |i| " ctx-after-#{i}" }
    body = [*ctx_before, "-old line", "+new line", *ctx_after].join("\n")
    "diff --git a/big.rb b/big.rb\n--- a/big.rb\n+++ b/big.rb\n@@ -1,61 +1,61 @@\n#{body}\n"
  end

  # A LOCKFILE diff — collapses to a one-line generated-file summary.
  let(:lockfile_diff) do
    body = (1..40).map { |i| i.even? ? "+    gem-#{i} (1.0)" : "-    gem-#{i} (0.9)" }.join("\n")
    "diff --git a/Gemfile.lock b/Gemfile.lock\n--- a/Gemfile.lock\n+++ b/Gemfile.lock\n@@ -1,40 +1,40 @@\n#{body}\n"
  end

  context "when compression is disabled (default)" do
    it "passes everything through" do
      result = router.route(noisy_log, tool_name: "shell")
      expect(result.applied?).to be false
      expect(result.strategy).to eq(:passthrough)
      expect(result.content_type).to eq(:disabled)
    end
  end

  context "when enabled" do
    before { enable! }

    it "routes a shell log → :log compression (keeps ERROR, drops INFO noise)" do
      result = router.route(noisy_log, tool_name: "shell")
      expect(result.applied?).to be true
      expect(result.content_type).to eq(:log)
      expect(result.text).to include("ERROR boom happened")
      expect(result.text.scan("INFO processing").length).to be < 60
    end

    it "routes a whole-file Ruby read → :code skeleton and exposes elided ranges" do
      hint = { full_file: true, source_path: "calc.rb", content_type: :code }
      result = router.route(ruby_source, tool_name: "read", compress_hint: hint)
      expect(result.applied?).to be true
      expect(result.content_type).to eq(:code)
      expect(result.text).to include("def big_method")
      expect(result.text).to include("elided")
      expect(router.last_elided_ranges).not_to be_empty
    end

    it "PASSES THROUGH a grep/search result byte-identical (safety)" do
      result = router.route(grep_output, tool_name: "grep")
      expect(result.applied?).to be false
      expect(result.content_type).to eq(:grep)
    end

    it "PASSES THROUGH a SMALL diff byte-identical (saving guard — 'show me')" do
      result = router.route(diff_output, tool_name: "shell", compress_hint: { stream_kind: :diff })
      expect(result.applied?).to be false
      expect(result.content_type).to eq(:diff)
    end

    it "DETECTS a small diff by content even without a hint (still passthrough)" do
      result = router.route(diff_output, tool_name: "shell")
      expect(result.applied?).to be false
      expect(result.content_type).to eq(:diff)
    end

    it "COMPRESSES a large wide-context diff, keeping every +/- line + headers" do
      result = router.route(wide_diff, tool_name: "shell", compress_hint: { stream_kind: :diff })
      expect(result.applied?).to be true
      expect(result.content_type).to eq(:diff)
      expect(result.strategy).to eq(:diff)
      expect(result.text).to include("-old line")
      expect(result.text).to include("+new line")
      expect(result.text).to include("diff --git a/big.rb b/big.rb")
      expect(result.text).to match(/^@@ /)
      expect(result.text).to match(/… \d+ unchanged lines/)
      # far context dropped, near context kept
      expect(result.text).not_to include(" ctx-before-1")
      expect(result.text).to include(" ctx-after-1")
    end

    it "COLLAPSES a lockfile diff to a one-line generated summary" do
      result = router.route(lockfile_diff, tool_name: "shell", compress_hint: { stream_kind: :diff })
      expect(result.applied?).to be true
      expect(result.content_type).to eq(:diff)
      expect(result.text).to include("diff --git a/Gemfile.lock b/Gemfile.lock")
      expect(result.text).to match(%r{Gemfile\.lock: \+\d+/-\d+ lines, 1 hunk — elided \(generated\)})
    end

    it "PASSES THROUGH short output untouched" do
      result = router.route("one\ntwo\nthree", tool_name: "shell")
      expect(result.applied?).to be false
      expect(result.content_type).to eq(:short)
    end

    it "DETECTS JSON and routes to passthrough (future extension point)" do
      json = "{\n#{(1..10).map { |i| %(  "key#{i}": #{i}) }.join(",\n")}\n}"
      result = router.route(json, tool_name: "shell")
      expect(result.applied?).to be false
      expect(result.content_type).to eq(:json)
    end

    it "honors the per-call compress:false opt-out (unconditional passthrough)" do
      result = router.route(noisy_log, tool_name: "shell", compress: false)
      expect(result.applied?).to be false
      expect(result.content_type).to eq(:opt_out)
    end

    it "does NOT skeletonise a targeted (non-whole-file) read" do
      result = router.route(ruby_source, tool_name: "read", compress_hint: { full_file: false })
      # falls through to :log? no — read isn't a log tool, so :other passthrough
      expect(result.applied?).to be false
    end

    it "falls back to passthrough when a strategy raises (never breaks the tool)" do
      allow(Rubino::Compression::LogCompressor).to receive(:new).and_raise("boom")
      result = router.route(noisy_log, tool_name: "shell")
      expect(result.applied?).to be false
      expect(result.content_type).to eq(:error)
    end
  end
end
