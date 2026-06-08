# frozen_string_literal: true

# Regression specs for #97: the `--image`/`-i` option used to be `type: :array`,
# which makes Thor greedily consume the trailing positional prompt as a second
# image. It is now a repeatable single-value string, so the positional prompt
# survives. These specs drive the real Thor parser (Commands.start) and capture
# the options/prompt handed to ChatCommand.
RSpec.describe Rubino::CLI::Commands do
  # Capture what Thor parsed without running the agent.
  let(:fake_chat) { instance_double(Rubino::CLI::ChatCommand, execute: nil) }
  let(:captured)  { {} }

  before do
    allow(Rubino::CLI::ChatCommand).to receive(:new) do |opts|
      captured[:opts] = opts
      fake_chat
    end
  end

  def run(*argv)
    described_class.start(argv)
    captured[:opts]
  end

  describe "chat --image with a trailing positional prompt (#97)" do
    it "keeps the prompt as the prompt, not as a second image" do
      opts = run("chat", "--image", "pic.png", "what is this?")
      expect(opts["image"]).to eq(["pic.png"])
      expect(opts[:query]).to eq("what is this?")
    end

    it "works through the -i alias too" do
      opts = run("chat", "-i", "pic.png", "what is this?")
      expect(opts["image"]).to eq(["pic.png"])
      expect(opts[:query]).to eq("what is this?")
    end

    it "accepts repeated --image flags for multiple images" do
      opts = run("chat", "--image", "a.png", "--image", "b.png", "describe both")
      expect(opts["image"]).to eq(["a.png", "b.png"])
      expect(opts[:query]).to eq("describe both")
    end

    it "still works with a single --image and no prompt" do
      opts = run("chat", "--image", "pic.png")
      expect(opts["image"]).to eq(["pic.png"])
      expect(opts[:query]).to be_nil
    end
  end

  describe "prompt subcommand --image with a positional prompt (#97)" do
    it "keeps the positional words as the prompt, not as images" do
      opts = run("prompt", "--image", "pic.png", "what", "is", "this?")
      expect(opts["image"]).to eq(["pic.png"])
      expect(opts[:query]).to eq("what is this?")
    end

    it "accepts repeated --image flags" do
      opts = run("prompt", "--image", "a.png", "--image", "b.png", "describe both")
      expect(opts["image"]).to eq(["a.png", "b.png"])
      expect(opts[:query]).to eq("describe both")
    end
  end
end
