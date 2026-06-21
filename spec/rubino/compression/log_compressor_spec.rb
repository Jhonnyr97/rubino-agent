# frozen_string_literal: true

RSpec.describe Rubino::Compression::LogCompressor do
  subject(:compressor) { described_class.new(config) }

  let(:config) do
    { "min_lines" => 10, "max_total_lines" => 100, "max_errors" => 10,
      "max_warnings" => 5, "max_stack_traces" => 3, "context_lines" => 4 }
  end

  # A realistic rspec run: a long green progress section (whose test NAMES carry
  # "error"/"fail" keywords — the trap), then the Failures: report + tally.
  def rspec_output(failures:)
    progress = (1..200).map do |i|
      "  handles an error case #{i} and fails gracefully when input is bad"
    end
    blocks = (1..failures).map do |n|
      <<~BLOCK.chomp
        #{n}) MyThing##{n} does the #{n}th thing
           Failure/Error: expect(x).to eq(#{n})

             expected: #{n}
                  got: 0
           # ./spec/my_thing_spec.rb:#{n}:in `block (2 levels) in <top (required)>'
      BLOCK
    end
    reruns = (1..failures).map { |n| "rspec ./spec/my_thing_spec.rb:#{n} # MyThing##{n}" }
    ([
      "Randomized with seed 123", ""
    ] + progress + [
      "", "Failures:", ""
    ] + blocks + [
      "", "Finished in 12.3 seconds (files took 1 second to load)",
      "#{200 + failures} examples, #{failures} failures, 2 pending",
      "", "Failed examples:", ""
    ] + reruns).join("\n")
  end

  describe "format detection" do
    it "detects rspec from the Failures:/examples shape" do
      result = compressor.compress(rspec_output(failures: 3))
      expect(result.applied?).to be(true)
      expect(result.strategy).to eq(:log)
    end
  end

  describe "FIDELITY INVARIANT" do
    [3, 21, 30].each do |k|
      it "keeps all #{k} failure descriptors and the summary tally" do
        out = compressor.compress(rspec_output(failures: k)).text

        # every numbered descriptor survives
        (1..k).each do |n|
          expect(out).to match(/^\s*#{n}\) MyThing##{n} does the #{n}th thing/),
                         "lost descriptor #{n}"
        end
        # every Failure/Error body survives
        expect(out.scan("Failure/Error:").length).to eq(k)
        # the final tally survives, verbatim
        expect(out).to include("#{200 + k} examples, #{k} failures, 2 pending")
      end
    end

    it "does NOT let the green progress section masquerade as failures" do
      out = compressor.compress(rspec_output(failures: 2)).text
      # the 200 "handles an error ... fails gracefully" progress lines are noise
      expect(out.scan("handles an error case").length).to be < 5
    end
  end

  describe "small-output passthrough" do
    it "is a no-op below min_lines" do
      tiny = (1..5).map { |i| "line #{i}" }.join("\n")
      result = compressor.compress(tiny)
      expect(result.applied?).to be(false)
      expect(result.strategy).to eq(:too_small)
    end
  end

  describe "generic logs (no test format)" do
    it "keeps ERROR lines and drops INFO noise" do
      log = (
        (1..50).map { |i| "INFO  request #{i} served in 4ms" } +
        ["ERROR  database connection refused at db:5432"] +
        (1..50).map { |i| "INFO  request #{50 + i} served in 4ms" }
      ).join("\n")
      out = compressor.compress(log).text
      expect(out).to include("ERROR  database connection refused at db:5432")
      expect(out.scan("INFO  request").length).to be < 100
    end
  end

  describe "conservative dedup of warnings" do
    # Normalization masks only the TRAILING region (after the first `:`/`=`), so
    # two warnings whose DISTINGUISHING token is in the PREFIX are never merged.
    it "does NOT collapse two warnings that differ in their prefix" do
      log = (
        ["foo.rb:10: warning: method redefined: was: old",
         "bar.rb:20: warning: method redefined: was: old"] +
        (1..50).map { |i| "passed example #{i}" }
      ).join("\n")
      out = compressor.compress(log).text
      expect(out).to include("foo.rb:10:")
      expect(out).to include("bar.rb:20:")
    end

    # Identical-but-repeated warnings DO collapse to a single kept line.
    it "collapses exact-duplicate warnings" do
      log = (
        Array.new(8, "deprecation warning: use the new API") +
        (1..50).map { |i| "passed example #{i}" }
      ).join("\n")
      out = compressor.compress(log).text
      expect(out.scan("deprecation warning: use the new API").length).to eq(1)
    end
  end

  describe "marker + counting" do
    it "replaces a run of dropped lines with a single marker" do
      log = (
        ["ERROR boom"] + (1..60).map { |i| "INFO noise #{i}" }
      ).join("\n")
      out = compressor.compress(log).text
      expect(out).to match(/\[… \d+ lines hidden by log compression …\]/)
      expect(out).to include("ERROR boom")
    end
  end

  describe "total cap" do
    it "never trims a failure to satisfy max_total_lines" do
      tight = config.merge("max_total_lines" => 30)
      out = described_class.new(tight).compress(rspec_output(failures: 25)).text
      (1..25).each { |n| expect(out).to include(") MyThing##{n} ") }
    end
  end
end
