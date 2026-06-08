# frozen_string_literal: true

RSpec.describe Rubino::Tools::VisionTool do
  subject(:tool) { described_class.new }

  let(:tmp_dir) { Dir.mktmpdir("vision_tool_spec") }
  after { FileUtils.rm_rf(tmp_dir) }

  it "has name 'vision' and :low risk" do
    expect(tool.name).to eq("vision")
    expect(tool.risk_level).to eq(:low)
  end

  describe "input validation" do
    it "rejects empty file_path" do
      expect(tool.call("file_path" => "")).to include("file_path is required")
    end

    it "rejects non-existent file" do
      expect(tool.call("file_path" => "/no/such/file.png")).to include("file not found")
    end

    it "rejects a directory" do
      expect(tool.call("file_path" => tmp_dir)).to include("not a regular file")
    end

    it "rejects an unsupported extension" do
      path = File.join(tmp_dir, "doc.pdf")
      File.binwrite(path, "%PDF-1.4\nfake")
      out = tool.call("file_path" => path)
      expect(out).to include("unsupported image extension")
      expect(out).to include(".png")
    end
  end

  describe "happy path" do
    let(:png_path) { File.join(tmp_dir, "img.png") }
    before { File.binwrite(png_path, "\x89PNG\r\n\x1A\nfake-image-bytes") }

    it "delegates to AuxiliaryClient and returns the response content" do
      response = Rubino::LLM::AdapterResponse.new(
        content: "A scatter plot with three clusters.",
        tool_calls: [], input_tokens: 0, output_tokens: 0, model_id: "fake"
      )
      aux = instance_double(Rubino::LLM::AuxiliaryClient, call: response)
      allow(Rubino::LLM::AuxiliaryClient).to receive(:new).and_return(aux)

      expect(aux).to receive(:call) do |task:, messages:, image_paths:|
        expect(task).to eq(:vision)
        expect(messages.first[:role]).to eq("user")
        # Image rides ruby_llm's native `with:` slot (image_paths), NOT an
        # OpenAI-style content array — the array path got stringified and the
        # model hallucinated (prod sessions 38/41). Content is plain text.
        expect(messages.first[:content]).to be_a(String)
        expect(image_paths).to eq([png_path])
        response
      end

      out = tool.call("file_path" => png_path)
      expect(out).to eq("A scatter plot with three clusters.")
    end

    it "uses the user-supplied question when given" do
      response = Rubino::LLM::AdapterResponse.new(
        content: "X axis says time.", tool_calls: [], input_tokens: 0, output_tokens: 0, model_id: "fake"
      )
      aux = instance_double(Rubino::LLM::AuxiliaryClient)
      allow(Rubino::LLM::AuxiliaryClient).to receive(:new).and_return(aux)

      expect(aux).to receive(:call) do |task:, messages:, image_paths:|
        expect(messages.first[:content]).to eq("What's on the X axis?")
        expect(image_paths).to eq([png_path])
        response
      end

      tool.call("file_path" => png_path, "question" => "What's on the X axis?")
    end

    it "returns a string error when the aux call raises" do
      aux = instance_double(Rubino::LLM::AuxiliaryClient)
      allow(Rubino::LLM::AuxiliaryClient).to receive(:new).and_return(aux)
      allow(aux).to receive(:call).and_raise(StandardError, "upstream 503")

      out = tool.call("file_path" => png_path)
      expect(out).to include("Error calling vision model")
      expect(out).to include("upstream 503")
    end
  end
end
