# frozen_string_literal: true

require "timeout"

# Ctrl+D at the EMPTY idle composer must NOT hang. The composer's raw reader
# turns an empty-buffer Ctrl+D (or a closed stdin) into an EOF/quit: it sets an
# observable #quit_pending? flag and stops. #read_idle_line's poll loop checks
# that flag alongside its Ctrl+C flag and returns nil (EOF), so the REPL
# quit-guard (#confirm_quit?) runs — instead of sleep-spinning forever waiting
# for a line the (now-stopped) reader will never push.
#
# Contrast with the previously-broken path: the reader returned :done and the
# thread ended, but nothing reached input_queue and there was no flag, so the
# poll loop's `sleep(0.05)` looped indefinitely and the quit-guard never fired.
RSpec.describe Rubino::CLI::ChatCommand do
  describe "#read_idle_line on an empty-buffer Ctrl+D (EOF)" do
    # NOT the test subject — we drive its private #read_idle_line and stub the
    # idle-loop side-helpers, which RSpec/SubjectStub forbids on a declared
    # subject. A plain collaborator instance keeps the stubs legitimate.
    let(:command) { described_class.new({}) }
    let(:queue)   { Rubino::Interaction::InputQueue.new }

    # A fake composer that mimics the real one AFTER the reader saw an
    # empty-buffer Ctrl+D: #quit_pending? is true. We only stub the surface the
    # idle poll loop touches.
    let(:composer) do
      instance_double(
        Rubino::UI::BottomComposer,
        start: nil,
        buffer: "",
        stop: nil,
        quit_pending?: true,
        clear_quit_pending: nil
      )
    end

    before do
      allow(Rubino::UI::BottomComposer).to receive(:new).and_return(composer)
      # Route the StdoutProxy swap to a harmless object so the read does not
      # touch the real terminal.
      allow(Rubino::UI::StdoutProxy).to receive(:new).and_return($stdout)
      # Neutralize the idle-loop side-helpers so only the EOF path drives.
      allow(command).to receive_messages(
        seed_draft: nil,
        idle_cards: instance_double(Rubino::CLI::Chat::IdleCardHost, paint: nil, children_live?: false),
        update_polishing_indicator: false,
        auto_resolve_pending_subagent_request: false,
        build_prompt: "> ",
        build_status_line: "",
        composer_rail: nil
      )
    end

    it "returns nil (EOF) instead of hanging" do
      result = Timeout.timeout(3) do
        command.send(:read_idle_line, queue, nil, nil)
      end
      expect(result).to be_nil
    end

    it "observes and clears the quit flag" do
      expect(composer).to receive(:clear_quit_pending)
      Timeout.timeout(3) { command.send(:read_idle_line, queue, nil, nil) }
    end
  end

  # The REPL quit-guard runs on a nil idle line: a nil input from #next_input
  # means EOF/quit, so #confirm_quit? decides (exits cleanly with nothing
  # running, confirms with live children). This is the existing guard the EOF
  # signal now reaches.
  describe "#confirm_quit? on a nil idle line" do
    it "passes through (clean exit) when no background work is running" do
      command = described_class.new({})
      ui = Class.new(Rubino::UI::Null) do
        def interactive_terminal? = false
      end.new
      expect(command.send(:confirm_quit?, ui)).to be(true)
    end
  end
end
