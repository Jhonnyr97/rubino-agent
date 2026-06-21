# frozen_string_literal: true

RSpec.describe Rubino::Tools::RetrieveOutputTool do
  subject(:tool) { described_class.new }

  it "has name 'retrieve_output'" do
    expect(tool.name).to eq("retrieve_output")
  end

  it "returns the original output for a stored hash" do
    hash = Rubino::Compression::OutputStore.instance.put("the full original output")
    expect(tool.call("hash" => hash)).to eq("the full original output")
  end

  it "errors clearly when the hash is unknown / evicted" do
    out = tool.call("hash" => "f" * 64)
    expect(out).to include("no stored output")
  end

  it "errors when no hash is given" do
    expect(tool.call({})).to include("hash is required")
  end
end
