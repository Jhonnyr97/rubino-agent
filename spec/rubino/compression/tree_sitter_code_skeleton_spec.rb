# frozen_string_literal: true

RSpec.describe Rubino::Compression::TreeSitterCodeSkeleton do
  # The optional gem is the parser; without it (or an undownloadable grammar)
  # the skeletoner is a pure no-op. So a gem-less host stays green, the
  # real-parser examples skip cleanly; on a host WITH the gem they RUN.
  def self.tree_sitter?
    require "tree_sitter_language_pack"
    true
  rescue LoadError, StandardError
    false
  end

  let(:keep_max) { 4 }

  def build(skeleton, src, path: "m.js")
    yielded = []
    out = skeleton.build(src, pointer_path: path) { |first, count| yielded << [first, count] }
    [out, yielded]
  end

  describe "JavaScript (real tree-sitter `process`)", if: tree_sitter? do
    subject(:skeleton) { Rubino::Compression::JavascriptCodeSkeleton.new(keep_method_body_max_lines: keep_max) }

    # A file exercising every rule: a big top-level function (elided), an arrow
    # with an EXPRESSION body (never elided), an arrow with a BLOCK body
    # (elided), a one-liner (never elided), and a class with a small method
    # (kept) and a big method that contains a nested function (elided as ONE
    # unit — the nested function is pruned, not double-counted).
    let(:source) do
      <<~JS
        function big(a, b) {
          let v1 = 1;
          let v2 = 2;
          let v3 = 3;
          let v4 = 4;
          let v5 = 5;
          return v1 + v2 + v3 + v4 + v5;
        }

        const arrowExpr = (n) => n * 2;

        const arrowBlock = (n) => {
          let r = n;
          r += 1;
          r += 2;
          r += 3;
          r += 4;
          return r;
        };

        function oneLine(a) { return a; }

        class Calc {
          small() {
            return 1;
          }

          compute(a, b) {
            let s1 = 1;
            let s2 = 2;
            let s3 = 3;
            let s4 = 4;
            let s5 = 5;
            function helper() {
              let h1 = 1;
              let h2 = 2;
              let h3 = 3;
              let h4 = 4;
              let h5 = 5;
              return h1;
            }
            return helper();
          }
        }
      JS
    end

    it "elides a large function body behind the exact `//` pointer, signature kept" do
      out, = build(skeleton, source)
      expect(out).to include("function big(a, b) {\n")
      expect(out).to include("  // … 6 lines elided — read m.js offset=2 limit=6\n")
      expect(out).to include("}\n") # the closing brace line is kept
    end

    it "round-trips: the pointer offset/limit windows the ORIGINAL body bytes exactly" do
      out, = build(skeleton, source)
      pointer = out.lines.find { |l| l.include?("offset=2 limit=6") }
      m = pointer.match(/offset=(\d+) limit=(\d+)/)
      window = source.lines[(m[1].to_i - 1), m[2].to_i].join
      expect(window).to eq(<<~BODY.gsub(/^/, "  "))
        let v1 = 1;
        let v2 = 2;
        let v3 = 3;
        let v4 = 4;
        let v5 = 5;
        return v1 + v2 + v3 + v4 + v5;
      BODY
    end

    it "elides an arrow BLOCK body but NOT an arrow EXPRESSION body" do
      out, yielded = build(skeleton, source)
      # arrow with a {…} body is elided
      expect(yielded).to include([13, 6])
      expect(out).to include("const arrowBlock = (n) => {\n")
      expect(out).to include("  // … 6 lines elided — read m.js offset=13 limit=6\n")
      # arrow with an expression body has no brace block → kept whole
      expect(out).to include("const arrowExpr = (n) => n * 2;\n")
    end

    it "does NOT elide a one-line function (cannot round-trip)" do
      out, = build(skeleton, source)
      expect(out).to include("function oneLine(a) { return a; }\n")
    end

    it "keeps the class line + method signatures, elides a big method as ONE unit" do
      out, yielded = build(skeleton, source)
      expect(out).to include("class Calc {\n")
      expect(out).to include("  small() {\n")
      expect(out).to include("    return 1;\n") # small body kept whole
      expect(out).to include("  compute(a, b) {\n")
      # compute's body is a single elision; `helper` inside it is pruned, never
      # its own range → ranges stay non-overlapping.
      compute = yielded.select { |first, _| first == 29 }
      expect(compute.size).to eq(1)
      expect(compute.first).to eq([29, 14])
      # exactly the three elidable bodies, nothing from inside them
      expect(yielded).to contain_exactly([2, 6], [13, 6], [29, 14])
    end

    it "returns the source UNCHANGED when nothing is big enough to elide" do
      tiny = "function f() {\n  return 1;\n}\n"
      out, yielded = build(skeleton, tiny)
      expect(out).to eq(tiny)
      expect(yielded).to be_empty
    end
  end

  describe "TypeScript (.ts → :typescript)", if: tree_sitter? do
    subject(:skeleton) { Rubino::Compression::TypescriptCodeSkeleton.new(keep_method_body_max_lines: keep_max) }

    let(:source) do
      <<~TS
        interface Shape {
          area(): number;
          name: string;
        }

        function tsFun(a: number): number {
          let r = a;
          r += 1;
          r += 2;
          r += 3;
          r += 4;
          return r;
        }
      TS
    end

    it "does NOT elide an interface signature body but DOES elide a normal function" do
      out, yielded = build(skeleton, source, path: "m.ts")
      # the interface (a container of bodiless signatures) is kept whole
      expect(out).to include("interface Shape {\n")
      expect(out).to include("  area(): number;\n")
      expect(out).to include("  name: string;\n")
      # the normal function body is elided
      expect(out).to include("function tsFun(a: number): number {\n")
      expect(out).to include("  // … 6 lines elided — read m.ts offset=7 limit=6\n")
      expect(yielded).to contain_exactly([7, 6])
    end
  end

  describe "TSX (.tsx → :tsx)", if: tree_sitter? do
    subject(:skeleton) { Rubino::Compression::TsxCodeSkeleton.new(keep_method_body_max_lines: keep_max) }

    let(:source) do
      <<~TSX
        const App = () => {
          const x = 1;
          const y = 2;
          const z = 3;
          const w = 4;
          const q = 5;
          return <div>{x + y + z + w + q}</div>;
        };
      TSX
    end

    it "elides an arrow-component BLOCK body" do
      out, yielded = build(skeleton, source, path: "App.tsx")
      expect(out).to include("const App = () => {\n")
      expect(out).to include("  // … 6 lines elided — read App.tsx offset=2 limit=6\n")
      expect(yielded).to contain_exactly([2, 6])
    end
  end

  describe "NO-OP fallback when the gem cannot load" do
    let(:source) { "function f() {\n  let a = 1;\n  return a;\n}\n" }

    before do
      # Simulate the gem being absent: the lazy require inside collect_elisions
      # raises LoadError, which the skeletoner maps to a no-op (nil) passthrough.
      allow_any_instance_of(Rubino::Compression::JavascriptCodeSkeleton) # rubocop:disable RSpec/AnyInstance
        .to receive(:require).with("tree_sitter_language_pack").and_raise(LoadError, "cannot load such file")
    end

    it "returns nil when the gem is absent (LoadError from the lazy require)" do
      skeleton = Rubino::Compression::JavascriptCodeSkeleton.new(keep_method_body_max_lines: keep_max)
      expect(skeleton.build(source, pointer_path: "x.js")).to be_nil
    end

    it "Compressor#compress(language: :javascript) yields a passthrough no-op" do
      pad = (["// pad"] * 12).join("\n")
      big = "function big() {\n#{(1..10).map { |i| "  let v#{i} = #{i};" }.join("\n")}\n  return 1;\n}"
      src = "#{pad}\n#{big}\n"
      compressor = Rubino::Compression::Compressor.new(min_lines: 5, keep_method_body_max_lines: 4)
      result = compressor.compress(src, source_path: "m.js", content_type: :code,
                                        full_file: true, language: :javascript)
      expect(result.applied?).to be(false)
      expect(result.strategy).to eq(:parse_error)
    end
  end
end
