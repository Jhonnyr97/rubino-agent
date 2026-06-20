# frozen_string_literal: true

require "faraday"

# #311 growing-conversation-tail breakpoint. The middleware stamps cache_control
# on the last content block of the last message of EVERY outgoing Anthropic
# /messages request — including the intermediate tool round-trips ruby_llm runs
# inside a single ask(), which #532's load_history tail-stamping never saw.
RSpec.describe Rubino::LLM::CacheBreakpointMiddleware do
  # Drive the middleware exactly as Faraday would: build a one-handler stack
  # whose terminal app captures the (possibly mutated) request body and returns
  # a canned 200. The body is a Hash because the middleware is installed BEFORE
  # Faraday::Request::Json (the real wiring), so it sees ruby_llm's Hash.
  def run(body)
    captured = nil
    app = lambda { |env|
      captured = env.request_body
      Faraday::Response.new(env)
    }
    mw = described_class.new(app)
    env = Faraday::Env.new
    env.request_body = body
    mw.call(env)
    captured
  end

  def cc?(block)
    block.is_a?(Hash) && block.key?("cache_control")
  end

  def text(str) = { "type" => "text", "text" => str }
  def tool_use(id) = { "type" => "tool_use", "id" => id, "name" => "read", "input" => {} }
  def tool_result(id, out) = { "type" => "tool_result", "tool_use_id" => id, "content" => out }

  describe "moving-tail stamping" do
    it "stamps a plain-text tail block" do
      body = { "messages" => [{ "role" => "user", "content" => [text("hi")] }] }
      out = run(body)
      expect(cc?(out["messages"].last["content"].last)).to be(true)
    end

    it "stamps an assistant tool_use tail UNCONDITIONALLY (tool round-trip)" do
      body = { "messages" => [
        { "role" => "user", "content" => [text("read a.rb")] },
        { "role" => "assistant", "content" => [text("ok"), tool_use("t1")] }
      ] }
      out = run(body)
      last = out["messages"].last["content"].last
      expect(last["type"]).to eq("tool_use")
      expect(cc?(last)).to be(true)
    end

    it "stamps a tool_result tail UNCONDITIONALLY (tool round-trip)" do
      body = { "messages" => [
        { "role" => "assistant", "content" => [tool_use("t1")] },
        { "role" => "user", "content" => [tool_result("t1", "file body")] }
      ] }
      out = run(body)
      last = out["messages"].last["content"].last
      expect(last["type"]).to eq("tool_result")
      expect(cc?(last)).to be(true)
    end

    it "only stamps the LAST block of the last message" do
      body = { "messages" => [{ "role" => "assistant",
                                "content" => [text("a"), text("b"), tool_use("t1")] }] }
      out = run(body)
      blocks = out["messages"].last["content"]
      expect(cc?(blocks[0])).to be(false)
      expect(cc?(blocks[1])).to be(false)
      expect(cc?(blocks[2])).to be(true)
    end

    it "skips a bare-string content tail cleanly (nothing to stamp)" do
      body = { "messages" => [{ "role" => "user", "content" => "plain string" }] }
      out = run(body)
      expect(out["messages"].last["content"]).to eq("plain string")
    end
  end

  describe "leapfrog breakpoint on long turns" do
    it "adds a second breakpoint ~15 blocks behind the tail when >20 blocks" do
      # 25 text blocks spread across messages → leapfrog at index size-1-15.
      blocks = Array.new(25) { |i| text("b#{i}") }
      body = { "messages" => [{ "role" => "user", "content" => blocks }] }
      out = run(body)
      stamped = out["messages"].last["content"].each_index.select { |i| cc?(out["messages"].last["content"][i]) }
      expect(stamped.size).to eq(2)
      expect(stamped).to include(24)             # tail
      expect(stamped).to include(24 - 15)        # leapfrog
    end

    it "does NOT add a leapfrog at or below the 20-block threshold" do
      blocks = Array.new(20) { |i| text("b#{i}") }
      body = { "messages" => [{ "role" => "user", "content" => blocks }] }
      out = run(body)
      stamped = out["messages"].last["content"].count { |b| cc?(b) }
      expect(stamped).to eq(1)
    end
  end

  describe "4-breakpoint cap (evict oldest message breakpoint, never system/tools)" do
    it "evicts the OLDEST message-level breakpoint to stay within the cap" do
      # 2 static breakpoints (1 tool + 1 system) + 2 pre-existing message
      # breakpoints. Adding the tail (a 3rd message-level one) would total 5 →
      # the oldest message breakpoint must be evicted, system/tools untouched.
      tool = { "name" => "read", "cache_control" => { "type" => "ephemeral" } }
      sys  = [{ "type" => "text", "text" => "sys", "cache_control" => { "type" => "ephemeral" } }]
      m1   = { "type" => "text", "text" => "old", "cache_control" => { "type" => "ephemeral" } }
      m2   = { "type" => "text", "text" => "mid", "cache_control" => { "type" => "ephemeral" } }
      body = {
        "tools" => [tool],
        "system" => sys,
        "messages" => [
          { "role" => "user", "content" => [m1] },
          { "role" => "assistant", "content" => [m2] },
          { "role" => "user", "content" => [text("new tail")] }
        ]
      }
      out = run(body)
      # static breakpoints intact
      expect(cc?(out["tools"].first)).to be(true)
      expect(cc?(out["system"].first)).to be(true)
      # oldest message breakpoint evicted, newer one + tail kept ⇒ 2 on messages
      msg_bps = out["messages"].flat_map { |m| m["content"] }.count { |b| cc?(b) }
      expect(msg_bps).to eq(2)
      expect(cc?(m1)).to be(false) # oldest evicted
      expect(cc?(out["messages"].last["content"].last)).to be(true) # tail stamped
    end
  end

  describe "defensive behavior" do
    it "leaves a non-messages payload untouched" do
      body = { "input" => "embed me" }
      expect(run(body)).to eq("input" => "embed me")
    end

    it "leaves invalid JSON string bodies untouched" do
      expect(run("not json {")).to eq("not json {")
    end

    it "restamps a String JSON body (defensive fallback path)" do
      json = JSON.generate("messages" => [{ "role" => "user", "content" => [text("hi")] }])
      out = run(json)
      parsed = JSON.parse(out)
      expect(cc?(parsed["messages"].last["content"].last)).to be(true)
    end

    it "is idempotent — restamping an already-stamped tail does not duplicate" do
      blk = text("hi").merge("cache_control" => { "type" => "ephemeral" })
      body = { "messages" => [{ "role" => "user", "content" => [blk] }] }
      out = run(body)
      expect(out["messages"].last["content"].last["cache_control"]).to eq("type" => "ephemeral")
    end
  end
end
