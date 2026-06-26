# frozen_string_literal: true

require "spec_helper"
require "rubino/llm/tool_call_recovery"

RSpec.describe Rubino::LLM::ToolCallRecovery do
  def recover(content) = described_class.recover(content)

  describe "family B — XML invoke/parameter (MiniMax, Qwen3-Coder)" do
    it "recovers a MiniMax-M3 tool call leaked with the ]<]minimax[>[ marker and cleans the text" do
      leaked = "Bene, vado.]<]minimax[>[<tool_call>" \
               ']<]minimax[>[<invoke name="shell">]<]minimax[>[<command>ls -la /work]<]minimax[>[</command>' \
               "]<]minimax[>[</invoke>]<]minimax[>[</tool_call>"
      r = recover(leaked)
      expect(r.calls).to eq([{ name: "shell", arguments: { "command" => "ls -la /work" } }])
      expect(r.text).to eq("Bene, vado.")
      expect(r.text).not_to include("minimax")
      expect(r.text).not_to include("<invoke")
    end

    it "recovers <parameter name=\"...\"> dialect (MiniMax-M2)" do
      leaked = '<invoke name="write"><parameter name="path">/tmp/a.txt</parameter>' \
               '<parameter name="content">hi</parameter></invoke>'
      r = recover(leaked)
      expect(r.calls).to eq([{ name: "write", arguments: { "path" => "/tmp/a.txt", "content" => "hi" } }])
    end

    it "recovers multiple invoke blocks in one message" do
      leaked = '<invoke name="a"><x>1</x></invoke><invoke name="b"><y>2</y></invoke>'
      r = recover(leaked)
      expect(r.calls.map { |c| c[:name] }).to eq(%w[a b])
    end

    # MiniMax-M3's ]<]minimax[>[ namespace token (chars ] < [ >) collides with
    # XML delimiters and the gateway mis-segments the tag, dropping name= and
    # leaving the tool name floating between two `">` (llama.cpp #24523, mlx-lm
    # #1145). No upstream parser recovers this; the tolerant matcher must.
    it "recovers M3's GARBLED <invoke\">shell\"> form (name= dropped)" do
      leaked = 'Faccio.]<]minimax[>[<tool_call>]<]minimax[>[<invoke">shell">' \
               "]<]minimax[>[<command>cd /work && ls]<]minimax[>[</command>" \
               "]<]minimax[>[</invoke>]<]minimax[>[</tool_call>"
      r = recover(leaked)
      expect(r.calls).to eq([{ name: "shell", arguments: { "command" => "cd /work && ls" } }])
      expect(r.text).to eq("Faccio.")
    end

    it "recovers an invoke that lost its leading angle bracket (M3 #1145)" do
      r = recover('invoke name="write"><path>/tmp/a</path></invoke>')
      expect(r.calls).to eq([{ name: "write", arguments: { "path" => "/tmp/a" } }])
    end
  end

  describe "family A — JSON in <tool_call> (Hermes, Qwen2.5/3)" do
    it "recovers a JSON tool call and removes the markup" do
      r = recover('Checking.<tool_call>{"name":"shell","arguments":{"command":"ls"}}</tool_call>')
      expect(r.calls).to eq([{ name: "shell", arguments: { "command" => "ls" } }])
      expect(r.text).to eq("Checking.")
    end

    it "accepts a stringified arguments payload" do
      r = recover('<tool_call>{"name":"f","arguments":"{\"k\":1}"}</tool_call>')
      expect(r.calls).to eq([{ name: "f", arguments: { "k" => 1 } }])
    end
  end

  describe "family C — [TOOL_CALLS] JSON array (Mistral)" do
    it "recovers each call from the array" do
      r = recover('[TOOL_CALLS][{"name":"w","arguments":{"city":"Roma"}}]')
      expect(r.calls).to eq([{ name: "w", arguments: { "city" => "Roma" } }])
    end
  end

  describe "reasoning + repair conventions" do
    it "strips a leaked <think> block before extraction" do
      r = recover('<think>plan: call ls</think><invoke name="shell"><command>ls</command></invoke>')
      expect(r.text).to eq("")
      expect(r.calls.first[:name]).to eq("shell")
    end

    it "recovers an unterminated invoke (missing close tag) to EOF" do
      r = recover('<invoke name="shell"><parameter name="command">ls')
      expect(r.calls.first).to eq({ name: "shell", arguments: { "command" => "ls" } })
    end
  end

  describe "no false positives on prose" do
    it "leaves ordinary text with stray words untouched and recovers nothing" do
      text = "Use <function> in JS; we discussed tool_call design and invoke patterns."
      r = recover(text)
      expect(r.calls).to be_empty
      expect(r.text).to eq(text)
    end

    it "leaves a <tool_call> wrapper whose body is not a real call" do
      text = "<tool_call>not json</tool_call>"
      r = recover(text)
      expect(r.calls).to be_empty
    end

    it "is inert on empty content" do
      r = recover("")
      expect(r.calls).to be_empty
      expect(r.text).to eq("")
    end
  end
end
