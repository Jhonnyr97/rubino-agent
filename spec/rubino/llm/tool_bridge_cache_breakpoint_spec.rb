# frozen_string_literal: true

# #311 — the tool-block prompt-cache breakpoint. ToolBridge.install marks the
# LAST tool (deterministic registry order) with provider_params carrying
# cache_control, which RubyLLM's Anthropic provider deep_merges onto the wire
# def — caching the whole tool block. Only that one tool gets the breakpoint,
# and only when cache_tools is requested (anthropic-family + caching on).
RSpec.describe Rubino::LLM::ToolBridge, "tool cache breakpoint (#311)" do
  before(:all) { Rubino.loader.eager_load }

  # Minimal chat double: records the tools handed to with_tool, in order.
  let(:chat) do
    Class.new do
      attr_reader :tools

      def initialize
        @tools = []
      end

      def with_tool(tool)
        @tools << tool
        self
      end
    end.new
  end

  let(:tools) do
    [Rubino::Tools::ReadTool.new, Rubino::Tools::GrepTool.new, Rubino::Tools::EditTool.new]
  end

  it "puts cache_control on ONLY the last tool when cache_tools is on" do
    described_class.install(chat, tools, cache_tools: true)
    installed = chat.tools

    installed[0...-1].each do |t|
      expect(t.provider_params).to eq({})
    end
    expect(installed.last.provider_params).to eq(cache_control: { type: "ephemeral" })
  end

  it "RubyLLM deep_merges the breakpoint onto the wire def of the last tool" do
    described_class.install(chat, tools, cache_tools: true)
    last = chat.tools.last
    wire = RubyLLM::Providers::Anthropic::Tools.function_for(last)
    expect(wire[:cache_control]).to eq(type: "ephemeral")
    # ...and the rest of the def is intact (name/description/input_schema).
    expect(wire[:name]).to eq(last.name)
    expect(wire[:description]).to eq(last.description)
  end

  it "emits NO cache_control on any tool when cache_tools is off (default)" do
    described_class.install(chat, tools)
    chat.tools.each { |t| expect(t.provider_params).to eq({}) }
  end

  it "is deterministic — same input order ⇒ same tool carries the breakpoint" do
    described_class.install(chat, tools, cache_tools: true)
    first_run_marked = chat.tools.last.name

    chat2 = chat.class.new
    described_class.install(chat2, tools, cache_tools: true)
    expect(chat2.tools.last.name).to eq(first_run_marked)
  end
end
