# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rubino::UI::PasteStore do
  let(:config) do
    instance_double(Rubino::Config::Configuration,
                    paste_collapse_lines: 5,
                    paste_file_threshold_tokens: 8000)
  end
  let(:session_id) { "spec-session-#{SecureRandom.hex(4)}" }
  let(:store) { described_class.new(config: config, session_source: session_id) }

  def lines(count)
    Array.new(count) { |i| "line #{i + 1}" }.join("\n")
  end

  describe "#collapse?" do
    it "keeps a paste AT the threshold inline (boundary: 5 lines with default 5)" do
      expect(store.collapse?(lines(5))).to be(false)
    end

    it "collapses a paste one line OVER the threshold" do
      expect(store.collapse?(lines(6))).to be(true)
    end

    it "honors a configured threshold" do
      tight = described_class.new(
        config: instance_double(Rubino::Config::Configuration,
                                paste_collapse_lines: 2, paste_file_threshold_tokens: 8000),
        session_source: session_id
      )
      expect(tight.collapse?(lines(3))).to be(true)
      expect(tight.collapse?(lines(2))).to be(false)
    end
  end

  describe "#register (tier 1)" do
    it "returns a placeholder carrying the paste number and line count" do
      expect(store.register(lines(42))).to eq("[Pasted text #1 +42 lines]")
    end

    it "numbers multiple pastes sequentially (#2, #3, …)" do
      store.register(lines(6))
      expect(store.register(lines(7))).to eq("[Pasted text #2 +7 lines]")
      expect(store.register(lines(8))).to eq("[Pasted text #3 +8 lines]")
    end
  end

  describe "#expand" do
    it "expands a registered placeholder to the verbatim pasted body" do
      body  = lines(10)
      token = store.register(body)
      expect(store.expand("please review #{token} carefully"))
        .to eq("please review #{body} carefully")
    end

    it "expands multiple placeholders in one message" do
      a = store.register("a\n" * 6)
      b = store.register("b\n" * 7)
      expanded = store.expand("first #{a} then #{b}")
      expect(expanded).to include("a\na\na")
      expect(expanded).to include("b\nb\nb")
      expect(expanded).not_to include("[Pasted text")
    end

    it "consumes the entry on expansion (cleared on submit)" do
      token = store.register(lines(6))
      store.expand(token)
      expect(store.expand(token)).to eq(token) # second pass: literal
    end

    it "leaves an unregistered placeholder-shaped literal untouched" do
      expect(store.expand("[Pasted text #9 +99 lines]")).to eq("[Pasted text #9 +99 lines]")
    end

    it "passes non-strings and placeholder-free text through" do
      expect(store.expand(nil)).to be_nil
      expect(store.expand("plain")).to eq("plain")
    end
  end

  describe "tier 2 — file overflow" do
    let(:store) do
      described_class.new(
        config: instance_double(Rubino::Config::Configuration,
                                paste_collapse_lines: 5,
                                paste_file_threshold_tokens: 10), # ~40 chars
        session_source: session_id
      )
    end
    let(:body) { lines(20) } # well over 40 chars

    it "writes the body to <home>/sessions/<id>/paste_N.txt, readable verbatim" do
      store.register(body)
      path = File.join(Rubino.home_path, "sessions", session_id, "paste_1.txt")
      expect(File.read(path)).to eq(body)
    end

    it "expands the placeholder to a read-tool pointer instead of the content" do
      token    = store.register(body)
      path     = File.join(Rubino.home_path, "sessions", session_id, "paste_1.txt")
      expanded = store.expand("look at #{token}")
      expect(expanded).to include("saved to #{path}")
      expect(expanded).to include("read it with the read tool")
      expect(expanded).not_to include("line 7")
    end

    it "the saved file is readable through the read tool" do
      token = store.register(body)
      path  = store.expand(token)[/saved to (\S+)/, 1]
      out   = Rubino::Tools::ReadTool.new.call("file_path" => path)
      text  = out.is_a?(Hash) ? out[:output] : out
      expect(text).to include("line 20")
    end

    it "resolves a CALLABLE session source at write time" do
      current = "before"
      dynamic = described_class.new(
        config: instance_double(Rubino::Config::Configuration,
                                paste_collapse_lines: 5, paste_file_threshold_tokens: 10),
        session_source: -> { current }
      )
      current = session_id
      dynamic.register(body)
      expect(File).to exist(File.join(Rubino.home_path, "sessions", session_id, "paste_1.txt"))
    end

    it "falls back to inlining the body when the file write fails" do
      allow(File).to receive(:write).and_raise(Errno::EACCES)
      token = store.register(body)
      expect(store.expand(token)).to eq(body)
    end
  end

  describe "#placeholder_span" do
    it "returns the whole-token span when the cursor touches a registered token" do
      token  = store.register(lines(6))
      buffer = "see #{token} ok"
      start  = 4
      # Backspace anywhere inside/at-end-of the token resolves to the full span.
      expect(store.placeholder_span(buffer, start + 1)).to eq([start, token.length])
      expect(store.placeholder_span(buffer, start + token.length)).to eq([start, token.length])
    end

    it "returns nil outside the token and for unregistered lookalikes" do
      token  = store.register(lines(6))
      buffer = "see #{token} ok"
      expect(store.placeholder_span(buffer, 4)).to be_nil # before the token
      expect(store.placeholder_span("[Pasted text #9 +9 lines]", 5)).to be_nil
    end
  end
end
