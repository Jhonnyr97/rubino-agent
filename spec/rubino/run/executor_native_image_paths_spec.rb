# frozen_string_literal: true

# Covers Executor#native_image_paths — the gate that decides which
# downloaded attachments ride natively (as ruby_llm `with:`) vs which fall
# back to the text augment + vision-tool delegation path.
RSpec.describe Rubino::Run::Executor do
  subject(:executor) { described_class.new }

  describe "#native_image_paths" do
    def stub_vision_support(supported)
      cfg = Marshal.load(Marshal.dump(Rubino.configuration))
      allow(cfg).to receive(:model_supports_vision?).and_return(supported)
      allow(Rubino).to receive(:configuration).and_return(cfg)
    end

    it "returns [] when paths is nil" do
      stub_vision_support(true)
      expect(executor.send(:native_image_paths, nil)).to eq([])
    end

    it "returns [] when paths is empty" do
      stub_vision_support(true)
      expect(executor.send(:native_image_paths, [])).to eq([])
    end

    it "returns [] when the primary doesn't support vision (paths go to vision tool)" do
      stub_vision_support(false)
      paths = ["/tmp/a.png", "/tmp/b.jpg"]
      expect(executor.send(:native_image_paths, paths)).to eq([])
    end

    it "returns only image paths when the primary supports vision" do
      stub_vision_support(true)
      paths = ["/tmp/a.png", "/tmp/doc.pdf", "/tmp/b.webp", "/tmp/notes.txt"]
      expect(executor.send(:native_image_paths, paths)).to eq(["/tmp/a.png", "/tmp/b.webp"])
    end

    it "respects all supported image extensions" do
      stub_vision_support(true)
      paths = Rubino::LLM::ContentBuilder::SUPPORTED_IMAGE_TYPES.map { |ext| "/tmp/file#{ext}" }
      expect(executor.send(:native_image_paths, paths)).to eq(paths)
    end
  end
end
