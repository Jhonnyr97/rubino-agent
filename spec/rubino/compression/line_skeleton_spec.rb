# frozen_string_literal: true

RSpec.describe Rubino::Compression::LineSkeleton do
  subject(:skeleton) { fake_class.new(keep_method_body_max_lines: 4) }

  # A tiny concrete subclass that drives the base mechanics from a fixed list of
  # elisions, so we can test the generic splice/contract independently of any
  # parser. `collect_elisions` returns whatever we hand it (incl. nil).
  let(:fake_class) do
    Class.new(described_class) do
      attr_writer :plan

      private

      def collect_elisions(_source)
        @plan
      end
    end
  end

  let(:source) do
    <<~SRC
      def big
        a = 1
        b = 2
        c = 3
      end
    SRC
  end

  def elision(first, count)
    described_class::Elision.new(first_line: first, line_count: count, indent: nil)
  end

  describe "#build contract" do
    it "returns nil when collect_elisions signals an unparseable source" do
      skeleton.plan = nil
      expect(skeleton.build(source, pointer_path: "x.rb")).to be_nil
    end

    it "returns the source UNCHANGED when nothing is big enough to elide ([])" do
      skeleton.plan = []
      expect(skeleton.build(source, pointer_path: "x.rb")).to eq(source)
    end

    it "splices a single pointer line over the elided range" do
      skeleton.plan = [elision(2, 3)] # the 3 body lines (a/b/c)
      out = skeleton.build(source, pointer_path: "x.rb")
      expect(out).to eq(<<~OUT)
        def big
          # … 3 lines elided — read x.rb offset=2 limit=3
        end
      OUT
    end

    it "preserves the indentation of the elided body's first line on the pointer" do
      skeleton.plan = [elision(2, 3)]
      pointer = skeleton.build(source, pointer_path: "x.rb").lines.find { |l| l.include?("elided") }
      expect(pointer).to start_with("  # …") # 2-space body indent kept
    end

    it "uses the singular 'line' for a single-line elision" do
      skeleton.plan = [elision(2, 1)]
      out = skeleton.build(source, pointer_path: "x.rb")
      expect(out).to include("# … 1 line elided — read x.rb offset=2 limit=1")
    end

    it "yields each elision's exact 1-based (first_line, count) to the caller" do
      skeleton.plan = [elision(2, 3)]
      yielded = []
      skeleton.build(source, pointer_path: "x.rb") { |first, count| yielded << [first, count] }
      expect(yielded).to eq([[2, 3]])
    end

    it "round-trips: the pointer's offset/limit windows the original bytes exactly" do
      skeleton.plan = [elision(2, 3)]
      out = skeleton.build(source, pointer_path: "x.rb")
      m = out.lines.find { |l| l.include?("offset=") }.match(/offset=(\d+) limit=(\d+)/)
      window = source.lines[(m[1].to_i - 1), m[2].to_i].join
      expect(window).to eq("  a = 1\n  b = 2\n  c = 3\n")
    end
  end

  describe "the base class itself" do
    it "raises NotImplementedError if a subclass forgets #collect_elisions" do
      bare = Class.new(described_class).new(keep_method_body_max_lines: 4)
      expect { bare.build(source, pointer_path: "x.rb") }.to raise_error(NotImplementedError)
    end
  end
end
