# frozen_string_literal: true

RSpec.describe Rubino::Compression::PythonCodeSkeleton do
  subject(:skeleton) { described_class.new(keep_method_body_max_lines: keep_max) }

  let(:keep_max) { 4 }
  # A file that exercises every parity rule: a module-level body that's small
  # (kept), a decorated function with a big body (elided, decorator kept), a
  # one-line def (NOT elided), and a class with a small method (kept) and a big
  # method that itself contains a nested def (elided as ONE unit, not double
  # counted).
  let(:source) do
    <<~PY
      import os

      @decorator
      def decorated(x):
          a = 1
          b = 2
          c = 3
          d = 4
          e = 5
          return a + b + c + d + e

      def one_liner(): return 1

      class Calc:
          def small(self):
              return self.x

          def big(self, a, b):
              v1 = 1
              v2 = 2
              v3 = 3
              v4 = 4
              v5 = 5
              v6 = 6
              def nested():
                  q = 1
                  w = 2
                  e = 3
                  r = 4
                  t = 5
                  return q
              return nested()
    PY
  end

  # python3 is the parser — the skeletoner is a pure no-op without it. So CI on a
  # host with no Python stays green, the real-parser examples skip cleanly.
  def self.python3?
    system("python3", "--version", out: File::NULL, err: File::NULL)
  end

  def build(src = source)
    yielded = []
    out = skeleton.build(src, pointer_path: "m.py") { |first, count| yielded << [first, count] }
    [out, yielded]
  end

  describe "#build (real python3 ast)" do
    before { skip "python3 not on PATH" unless self.class.python3? }

    it "elides a large function body behind the exact pointer, decorator kept" do
      out, = build
      # the decorator and the def signature stay verbatim
      expect(out).to include("@decorator\n")
      expect(out).to include("def decorated(x):\n")
      # the body (lines 5..10, 6 lines) is replaced by one pointer
      expect(out).to include("    # … 6 lines elided — read m.py offset=5 limit=6\n")
    end

    it "round-trips: the pointer offset/limit windows the ORIGINAL body bytes exactly" do
      out, yielded = build
      pointer = out.lines.find { |l| l.include?("offset=5") }
      m = pointer.match(/offset=(\d+) limit=(\d+)/)
      window = source.lines[(m[1].to_i - 1), m[2].to_i].join
      expect(window).to eq(<<~BODY.gsub(/^/, "    "))
        a = 1
        b = 2
        c = 3
        d = 4
        e = 5
        return a + b + c + d + e
      BODY
      expect(yielded).to include([5, 6])
    end

    it "keeps class structure and small method signatures verbatim" do
      out, = build
      expect(out).to include("class Calc:\n")
      expect(out).to include("    def small(self):\n")
      expect(out).to include("        return self.x\n") # small body kept whole
      expect(out).to include("    def big(self, a, b):\n")
    end

    it "does NOT elide a one-line def (cannot round-trip, mirrors Ruby)" do
      out, = build
      expect(out).to include("def one_liner(): return 1\n")
    end

    it "elides a big method as ONE unit — a nested def inside it is not double counted" do
      _, yielded = build
      # `big`'s body starts on line 19 and runs to line 32 (14 lines) as a single
      # elision; `nested` inside it is pruned, so it never produces its own range.
      big = yielded.select { |first, _| first == 19 }
      expect(big.size).to eq(1)
      expect(big.first).to eq([19, 14])
      # exactly the two top-level big bodies, nothing from inside them
      expect(yielded).to contain_exactly([5, 6], [19, 14])
    end

    it "returns the source UNCHANGED when nothing is big enough to elide" do
      tiny = "def f():\n    return 1\n"
      out, yielded = build(tiny)
      expect(out).to eq(tiny)
      expect(yielded).to be_empty
    end

    it "returns nil (passthrough) on a Python SYNTAX error" do
      expect(skeleton.build("def (:::not python", pointer_path: "x.py")).to be_nil
    end
  end

  describe "NO-OP fallback when python3 cannot run" do
    it "returns nil when python3 is absent (Errno::ENOENT from the shell-out)" do
      allow(Open3).to receive(:capture3).and_raise(Errno::ENOENT, "python3")
      expect(skeleton.build(source, pointer_path: "x.py")).to be_nil
    end

    it "returns nil on a non-zero exit from the interpreter" do
      status = instance_double(Process::Status, success?: false)
      allow(Open3).to receive(:capture3).and_return(["", "boom", status])
      expect(skeleton.build(source, pointer_path: "x.py")).to be_nil
    end

    it "returns nil on malformed (non-JSON) output" do
      status = instance_double(Process::Status, success?: true)
      allow(Open3).to receive(:capture3).and_return(["not json at all", "", status])
      expect(skeleton.build(source, pointer_path: "x.py")).to be_nil
    end

    it "Compressor#compress(language: :python) yields a passthrough no-op" do
      allow(Open3).to receive(:capture3).and_raise(Errno::ENOENT, "python3")
      compressor = Rubino::Compression::Compressor.new(min_lines: 5, keep_method_body_max_lines: 4)
      result = compressor.compress(source, source_path: "m.py", content_type: :code, full_file: true,
                                           language: :python)
      expect(result.applied?).to be(false)
      expect(result.strategy).to eq(:parse_error)
    end
  end
end
