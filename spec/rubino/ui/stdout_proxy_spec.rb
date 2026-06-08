# frozen_string_literal: true

# Specs for the $stdout proxy that routes turn output through the composer.
# We drive it against a fake composer that records committed lines
# (print_above) and the current live partial (set_partial), so we can assert
# the partial-line buffering / commit-on-newline behaviour without a terminal.
RSpec.describe Rubino::UI::StdoutProxy do
  # Records the coordinator calls the proxy makes.
  let(:composer) do
    Class.new do
      attr_reader :committed
      def initialize
        @committed = []
        @partial = ""
      end

      def print_above(str)
        @committed << str
        @partial = ""
      end

      def set_partial(str)
        @partial = str.to_s
      end

      def partial
        @partial
      end
    end.new
  end

  subject(:proxy) { described_class.new(composer) }

  describe "partial writes (no newline)" do
    it "holds a partial write as the live partial, uncommitted" do
      proxy.print("half a line")
      expect(composer.committed).to eq([])
      expect(composer.partial).to eq("half a line")
    end

    it "grows the live partial across multiple partial writes" do
      proxy.print("foo")
      proxy.print("bar")
      expect(composer.committed).to eq([])
      expect(composer.partial).to eq("foobar")
    end

    it "commits the held partial when a newline finally arrives" do
      proxy.print("foo")
      proxy.print("bar\n")
      expect(composer.committed).to eq(["foobar"])
      expect(composer.partial).to eq("")
    end
  end

  describe "streaming token sequence then a newline" do
    it "commits exactly one line above the composer" do
      # Mimic UI::CLI#stream emitting partial tokens (no newline) then
      # stream_end emitting the terminating newline.
      ["Hel", "lo,", " ", "wor", "ld"].each { |tok| proxy.print(tok); proxy.flush }
      expect(composer.committed).to eq([]) # nothing committed yet
      expect(composer.partial).to eq("Hello, world")

      proxy.puts # stream_end → terminating newline
      expect(composer.committed).to eq(["Hello, world"])
      expect(composer.partial).to eq("")
    end
  end

  describe "#puts" do
    it "routes a single line through print_above" do
      proxy.puts("a finished line")
      expect(composer.committed).to eq(["a finished line"])
    end

    it "splits a multi-line argument into one commit per line" do
      proxy.puts("line one\nline two")
      expect(composer.committed).to eq(["line one", "line two"])
    end

    it "flattens array arguments" do
      proxy.puts(%w[a b])
      expect(composer.committed).to eq(%w[a b])
    end

    it "with no args commits a blank line" do
      proxy.print("partial")
      proxy.puts
      expect(composer.committed).to eq(["partial"])
    end
  end

  describe "#print of a string ending in newline" do
    it "commits immediately, leaving no partial" do
      proxy.print("complete\n")
      expect(composer.committed).to eq(["complete"])
      expect(composer.partial).to eq("")
    end
  end

  describe "#write" do
    it "routes through the same buffering and returns the byte count" do
      n = proxy.write("hi\n")
      expect(composer.committed).to eq(["hi"])
      expect(n).to eq(3)
    end
  end

  describe "#<<" do
    it "appends and returns self for chaining" do
      expect(proxy << "x").to be(proxy)
      expect(composer.partial).to eq("x")
    end
  end

  describe "#finish" do
    it "commits a dangling partial line on teardown" do
      proxy.print("unterminated tail")
      proxy.finish
      expect(composer.committed).to eq(["unterminated tail"])
    end

    it "is a no-op when there is no held partial" do
      proxy.puts("done")
      proxy.finish
      expect(composer.committed).to eq(["done"])
    end
  end

  describe "#live (replace, not accumulate)" do
    it "REPLACES the live partial rather than growing it" do
      proxy.print("an accumulated tail")
      proxy.live("the whole in-progress block")
      expect(composer.partial).to eq("the whole in-progress block")
      expect(composer.committed).to eq([])
    end

    it "replaces again on each call (the tail is re-shown whole)" do
      proxy.live("block v1")
      proxy.live("block v1 plus more")
      expect(composer.partial).to eq("block v1 plus more")
    end

    it "clears the live region with an empty string" do
      proxy.live("something")
      proxy.live("")
      expect(composer.partial).to eq("")
    end

    it "returns self for chaining" do
      expect(proxy.live("x")).to be(proxy)
    end
  end

  describe "IO duck-typing" do
    it "reports not-a-tty so callers don't probe terminal features" do
      expect(proxy.tty?).to be(false)
      expect(proxy.isatty).to be(false)
    end
  end
end
