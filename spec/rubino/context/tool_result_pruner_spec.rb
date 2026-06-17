# frozen_string_literal: true

# #415d: cheap LLM-free pre-pass that dedupes + summarizes old tool results
# in the compressible middle before the paid summary call.
RSpec.describe Rubino::Context::ToolResultPruner do
  subject(:pruner) { described_class.new }

  def msg(role, content, tool_name: nil)
    { role: role, content: content, tool_name: tool_name }
  end

  it "leaves small tool results and non-tool messages untouched" do
    rows = [msg("user", "do the thing"), msg("tool", "ok", tool_name: "shell")]
    expect(pruner.prune(rows)).to eq(rows)
  end

  it "replaces large tool results with a 1-line descriptor" do
    big = "x" * 5_000
    out = pruner.prune([msg("tool", big, tool_name: "read")])
    expect(out.first[:content]).to eq("[read result — 5000 chars, pruned for summary]")
  end

  it "dedupes identical large tool results, keeping a back-reference on older copies" do
    big = "y" * 1_000
    out = pruner.prune([
                         msg("tool", big, tool_name: "read"),
                         msg("user", "again"),
                         msg("tool", big, tool_name: "read")
                       ])
    # Older (first) copy becomes a duplicate back-reference; both end up
    # summarized/deduped — neither carries the original 1,000-char payload.
    contents = out.map { |m| m[:content] }
    expect(contents).to include("[Duplicate tool output — same content as a more recent call]")
    expect(contents.none? { |c| c.length >= 1_000 }).to be true
  end

  it "shrinks the total character footprint of a noisy middle" do
    rows = Array.new(4) { msg("tool", "z" * 3_000, tool_name: "grep") }
    before = rows.sum { |m| m[:content].length }
    after  = pruner.prune(rows).sum { |m| m[:content].length }
    expect(after).to be < before
  end

  it "accepts duck-typed message objects (Session::Message-like)" do
    obj = Struct.new(:role, :content, :tool_name).new("tool", "q" * 1_000, "read")
    out = pruner.prune([obj])
    expect(out.first[:content]).to start_with("[read result —")
  end
end
