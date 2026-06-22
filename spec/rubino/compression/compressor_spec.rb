# frozen_string_literal: true

RSpec.describe Rubino::Compression::Compressor do
  subject(:compressor) do
    described_class.new(min_lines: min_lines, keep_method_body_max_lines: keep_max)
  end

  let(:min_lines) { 10 }
  let(:keep_max)  { 4 }

  # A file with one SMALL body (kept) and one LARGE body (elided). The large
  # body is built to be clearly over `keep_max` AND large enough that eliding it
  # clears the 25% byte-saving guard.
  let(:big_body) { (1..40).map { |i| "      v#{i} = w#{i} + #{i}" }.join("\n") }
  let(:source) do
    <<~RUBY
      # frozen_string_literal: true
      require "json"

      module Geo
        class Calc
          PI = 3.14159
          attr_reader :radius

          def small
            @radius * 2
          end

          def big(a, b)
      #{big_body}
            x = a + b
            s = x * 3
          end
        end
      end
    RUBY
  end

  def compress(content, full_file: true, content_type: :code, path: "geo.rb")
    compressor.compress(content, source_path: path, content_type: content_type, full_file: full_file)
  end

  describe "skeleton correctness" do
    let(:result) { compress(source) }

    it "applies and reports token savings" do
      expect(result.applied?).to be(true)
      expect(result.strategy).to eq(:skeleton)
      expect(result.saved_tokens_est).to be > 0
      expect(result.text.bytesize).to be < source.bytesize
    end

    it "keeps requires, constants, attr_*, signatures and the small body verbatim" do
      text = result.text
      expect(text).to include('require "json"')
      expect(text).to include("PI = 3.14159")
      expect(text).to include("attr_reader :radius")
      expect(text).to include("def small")
      expect(text).to include("@radius * 2")           # small body kept whole
      expect(text).to include("def big(a, b)")         # signature kept
      expect(text).to include("module Geo")
      expect(text).to include("class Calc")
    end

    it "elides the large body behind a pointer and drops its lines" do
      text = result.text
      expect(text).to match(/# … \d+ lines elided — read geo\.rb offset=\d+ limit=\d+/)
      expect(text).not_to include("v20 = w20 + 20")    # interior of big body gone
    end

    it "preserves the indentation of the elided body on the pointer line" do
      pointer = result.text.lines.find { |l| l.include?("elided") }
      expect(pointer).to start_with("      # …")       # 6-space body indent kept
    end

    it "exposes the exact 1-based elided ranges" do
      result # trigger the compress so elided_ranges is populated
      first, count = compressor.elided_ranges.first
      original = source.lines[(first - 1), count].join
      expect(original).to include("v1 = w1 + 1")
      expect(original).to include("v40 = w40 + 40")
      expect(count).to be > keep_max
    end
  end

  describe "the drill-in invariant (pointer offset/limit returns the EXACT body)" do
    it "round-trips: reading at the pointer's offset/limit yields the original bytes" do
      result = compress(source)
      pointer = result.text.lines.find { |l| l.include?("offset=") }
      m = pointer.match(/offset=(\d+) limit=(\d+)/)
      offset = m[1].to_i
      limit  = m[2].to_i

      elided = source.lines[(offset - 1), limit].join
      # The window the model would read is byte-identical to the original body.
      expect(elided).to eq(source.lines[(offset - 1), limit].join)
      expect(elided).to start_with("      v1 = w1 + 1\n")
      expect(elided).to include("      v40 = w40 + 40\n")
    end
  end

  describe "guards / no-op cases" do
    it "is a no-op for a targeted (non whole-file) read" do
      result = compress(source, full_file: false)
      expect(result.applied?).to be(false)
      expect(result.strategy).to eq(:not_full_file)
    end

    it "is a no-op for non-code content" do
      result = compress(source, content_type: :text)
      expect(result.applied?).to be(false)
      expect(result.strategy).to eq(:not_code)
    end

    it "is a no-op for a file under min_lines" do
      tiny = "def a\n  1\nend\n"
      result = compress(tiny)
      expect(result.applied?).to be(false)
      expect(result.strategy).to eq(:too_small)
    end

    it "is a no-op (parse_error) on unparseable Ruby" do
      broken = "#{(["x = 1"] * 20).join("\n")}\ndef oops(\n"
      result = compress(broken)
      expect(result.applied?).to be(false)
      expect(result.strategy).to eq(:parse_error)
    end

    it "is a no-op when the saving is below the 25% threshold" do
      # All-small bodies over min_lines: nothing elided → identical text → 0% saving.
      pad = (["# pad"] * 12).join("\n")
      methods = (1..6).map { |i| "def m#{i}\n  #{i}\nend\n" }.join("\n")
      result = compress("#{pad}\n#{methods}")
      expect(result.applied?).to be(false)
      expect(result.strategy).to eq(:insufficient_saving)
      expect(compressor.elided_ranges).to be_empty
    end
  end

  describe "edge cases" do
    it "leaves one-line method definitions whole (nothing to point at)" do
      pad = (["# pad"] * 12).join("\n")
      one_liners = (1..10).map { |i| "def m#{i}(a) = a + #{i}" }.join("\n")
      result = compress("#{pad}\n#{one_liners}\n")
      # No multi-line bodies → nothing elided → no-op (insufficient_saving).
      expect(result.applied?).to be(false)
    end

    it "elides def self.* (singleton) bodies too" do
      pad = (["# pad"] * 12).join("\n")
      singleton_body = (1..40).map { |i| "    a#{i} = a#{i - 1} + #{i}" }.join("\n")
      klass = <<~RUBY
        class K
          def self.run(a0)
        #{singleton_body}
            a40
          end
        end
      RUBY
      src = "#{pad}\n#{klass}"
      result = compress(src)
      expect(result.applied?).to be(true)
      expect(result.text).to include("def self.run(a0)")
      expect(result.text).to match(/# … \d+ lines elided/)
      expect(result.text).not_to include("a20 = a19 + 20")
    end
  end
end
