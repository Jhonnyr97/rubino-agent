# frozen_string_literal: true

RSpec.describe Rubino::CLI::Commands do
  # #483: the `--help` footer and the `default_command :chat` comment promise
  # `rubino "your prompt"` as the one-shot entry, but Thor's `default_command`
  # does NOT forward a bare positional to chat's prompt arg — a bare prompt died
  # with "unknown command". A prompt-SHAPED bare argument must now route to a
  # one-shot `chat` run, WITHOUT breaking real commands, flags, or the
  # unknown-command did-you-mean for a lone typo'd word (#67, F2).
  describe "bare prompt one-shot routing (#483)" do
    describe ".bare_prompt_args" do
      it "routes a quoted multi-word prompt to chat" do
        expect(described_class.bare_prompt_args(["what is 2+2"]))
          .to eq(["what is 2+2"])
      end

      it "joins an unquoted multi-word prompt into chat's single PROMPT arg" do
        expect(described_class.bare_prompt_args(%w[what is 2+2]))
          .to eq(["what is 2+2"])
      end

      it "preserves trailing flags after the joined prompt" do
        expect(described_class.bare_prompt_args(["what is 2+2", "--yolo"]))
          .to eq(["what is 2+2", "--yolo"])
      end

      it "routes a single word that ends in sentence punctuation" do
        expect(described_class.bare_prompt_args(["hello?"])).to eq(["hello?"])
      end

      it "does NOT route a known command (setup/doctor/chat stay commands)" do
        expect(described_class.bare_prompt_args(%w[setup])).to be_nil
        expect(described_class.bare_prompt_args(%w[doctor])).to be_nil
        expect(described_class.bare_prompt_args(["chat", "hello there"])).to be_nil
      end

      it "does NOT route a leading flag (left to existing flag handling)" do
        expect(described_class.bare_prompt_args(%w[--version])).to be_nil
        expect(described_class.bare_prompt_args(%w[--frobnicate hello])).to be_nil
      end

      it "does NOT route a lone identifier-like word (keeps did-you-mean #67/F2)" do
        expect(described_class.bare_prompt_args(%w[frobnicate])).to be_nil
        expect(described_class.bare_prompt_args(%w[setpu])).to be_nil
      end

      it "does NOT route a lone unknown word followed only by flags (#327 envelope still fires)" do
        expect(described_class.bare_prompt_args(%w[bogus --output-format json])).to be_nil
      end

      # #483 sharp-edge: a 2-word TYPO of a real command (`confg show` for
      # `config show`) used to slip past as a multi-word prompt, hiding the
      # did-you-mean. A leading word that's a near-miss of a known command bails
      # so the closest-match suggestion (#67/F2) fires instead.
      it "does NOT route a 2-word TYPO of a real command (did-you-mean fires, #483)" do
        expect(described_class.bare_prompt_args(%w[confg show])).to be_nil
        expect(described_class.bare_prompt_args(%w[sessoins list])).to be_nil
      end

      it "STILL routes a genuine multi-word prompt whose lead is no near-command" do
        expect(described_class.bare_prompt_args(%w[what is 2 plus 2]))
          .to eq(["what is 2 plus 2"])
      end
    end

    it "dispatches a bare prompt to the chat command (one-shot)" do
      captured = nil
      allow(Rubino::CLI::ChatCommand).to receive(:new) do |opts|
        captured = opts
        instance_double(Rubino::CLI::ChatCommand, execute: nil)
      end

      described_class.start(["what is 2+2"])
      expect(captured["query"] || captured[:query]).to eq("what is 2+2")
    end

    it "still runs a real subcommand (`setup`) instead of treating it as a prompt" do
      allow(Rubino::CLI::ChatCommand).to receive(:new)
        .and_raise("setup must NOT be routed to chat")
      setup_cmd = instance_double(Rubino::CLI::SetupCommand, execute: nil)
      allow(Rubino::CLI::SetupCommand).to receive(:new).and_return(setup_cmd)

      described_class.start(["setup"])
      expect(setup_cmd).to have_received(:execute)
    end

    it "still prints top-level help for `--help` (not a one-shot prompt)" do
      expect { described_class.start(["--help"]) }
        .to output(/Commands:/).to_stdout
    end
  end

  # #490: `rubino chat help` / `rubino prompt help` reached ChatCommand with
  # "help" as the prompt, spent a turn, and persisted a spurious "help" session
  # row that cluttered `sessions`. A bare `help` positional must short-circuit to
  # the command's help BEFORE any session is created — no ChatCommand built.
  describe "chat/prompt `help` positional short-circuit (#490)" do
    before do
      # Any path that builds ChatCommand is the regression (a session would be
      # created/persisted).
      allow(Rubino::CLI::ChatCommand).to receive(:new)
        .and_raise("ChatCommand must never be built for a `help` invocation")
    end

    %w[chat prompt].each do |cmd|
      it "prints `#{cmd}` usage for `#{cmd} help` without building ChatCommand" do
        expect { described_class.start([cmd, "help"]) }
          .to output(/Usage:/m).to_stdout
      end
    end

    it "does NOT short-circuit a genuine prompt that merely starts with `help`" do
      captured = nil
      allow(Rubino::CLI::ChatCommand).to receive(:new) do |opts|
        captured = opts
        instance_double(Rubino::CLI::ChatCommand, execute: nil)
      end
      described_class.start(["chat", "help me debug this"])
      expect(captured["query"] || captured[:query]).to eq("help me debug this")
    end
  end
end
