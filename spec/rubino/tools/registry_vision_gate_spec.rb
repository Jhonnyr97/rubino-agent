# frozen_string_literal: true

# The vision tool gate must:
#   - hide vision when no aux is configured AND primary doesn't see (no path)
#   - expose vision when aux is configured (regardless of primary capability)
#   - expose vision when primary supports vision (even without aux)
RSpec.describe Rubino::Tools::Registry do
  before do
    described_class.reset!
    described_class.register(Rubino::Tools::VisionTool.new)
  end

  after do
    described_class.reset!
    described_class.register_defaults!
  end

  def stub_config(aux_model:, primary_vision:)
    cfg = Marshal.load(Marshal.dump(Rubino.configuration))
    cfg.set("auxiliary", "vision", "model", aux_model)
    allow(cfg).to receive(:model_supports_vision?).and_return(primary_vision)
    allow(Rubino).to receive(:configuration).and_return(cfg)
  end

  it "hides vision when no aux AND primary is text-only" do
    stub_config(aux_model: "", primary_vision: false)
    expect(described_class.enabled_tools.map(&:name)).not_to include("vision")
  end

  it "exposes vision when aux is configured (primary text-only)" do
    stub_config(aux_model: "auto-vision", primary_vision: false)
    expect(described_class.enabled_tools.map(&:name)).to include("vision")
  end

  it "exposes vision when primary supports it (no aux configured)" do
    stub_config(aux_model: "", primary_vision: true)
    expect(described_class.enabled_tools.map(&:name)).to include("vision")
  end

  it "exposes vision when both aux and primary support it (user may prefer to delegate)" do
    stub_config(aux_model: "auto-vision", primary_vision: true)
    expect(described_class.enabled_tools.map(&:name)).to include("vision")
  end
end
