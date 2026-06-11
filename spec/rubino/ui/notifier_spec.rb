# frozen_string_literal: true

# Attention notifications (UI::Notifier): the bell/command-hook signals for
# "the agent needs eyes" — a long turn finishing, an approval prompt, a
# blocked subagent. Channel rules under test:
#   * the BEL byte goes to the REAL terminal only (never into a pipe);
#   * quick turns stay silent (notifications.min_turn_seconds);
#   * the optional command hook is spawned detached with RUBINO_EVENT /
#     RUBINO_MESSAGE in its env, best-effort;
#   * bursts coalesce — at most one signal per COALESCE_SECONDS window.
RSpec.describe Rubino::UI::Notifier do
  # A StringIO that quacks like a real terminal so the pipe gate lets the
  # bell through and we can capture the exact bytes written.
  def tty_sink
    io = StringIO.new
    def io.tty? = true
    io
  end

  def build(notifications = {})
    described_class.new(config: test_configuration("notifications" => notifications))
  end

  def with_stdout(io)
    old = $stdout
    $stdout = io
    yield
  ensure
    $stdout = old
  end

  describe "bell channel" do
    it "rings the terminal bell on needs_approval" do
      sink = tty_sink
      with_stdout(sink) { build.needs_approval("shell wants: rm -rf build") }
      expect(sink.string).to include("\a")
    end

    it "rings on blocked (a subagent waiting on the human)" do
      sink = tty_sink
      with_stdout(sink) { build.blocked("sa_1 is waiting on you") }
      expect(sink.string).to include("\a")
    end

    it "never bells into a pipe (non-tty stdout)" do
      sink = StringIO.new # tty? is false
      with_stdout(sink) { build.needs_approval }
      expect(sink.string).to be_empty
    end

    it "prefers the composer's REAL output over the (proxied) $stdout" do
      real = tty_sink
      composer = instance_double(Rubino::UI::BottomComposer, output: real)
      allow(Rubino::UI::BottomComposer).to receive(:current).and_return(composer)
      with_stdout(StringIO.new) { build.needs_approval }
      expect(real.string).to include("\a")
    end

    it "stays silent when notifications.enabled is false" do
      sink = tty_sink
      with_stdout(sink) { build("enabled" => false).needs_approval }
      expect(sink.string).to be_empty
    end

    it "skips the bell (but not the hook) when notifications.bell is false" do
      allow(Process).to receive(:spawn).and_return(4242)
      allow(Process).to receive(:detach)
      sink = tty_sink
      with_stdout(sink) { build("bell" => false, "command" => "notify-send hi").needs_approval }
      expect(sink.string).to be_empty
      expect(Process).to have_received(:spawn)
    end

    it "appends an OSC 9 escape on iTerm2 (TERM_PROGRAM=iTerm.app)" do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("TERM_PROGRAM").and_return("iTerm.app")
      sink = tty_sink
      with_stdout(sink) { build.blocked("line1\nline2") }
      expect(sink.string).to include("\e]9;")
      # Control bytes in the message are scrubbed so they can't cut the
      # OSC sequence short.
      expect(sink.string).to include("line1 line2")
    end
  end

  describe "#turn_finished (the long-turn gate)" do
    it "stays silent for a quick turn (under min_turn_seconds)" do
      sink = tty_sink
      with_stdout(sink) { build.turn_finished(3.2) }
      expect(sink.string).to be_empty
    end

    it "rings for a long turn" do
      sink = tty_sink
      with_stdout(sink) { build.turn_finished(42.7) }
      expect(sink.string).to include("\a")
    end

    it "honors a configured min_turn_seconds" do
      sink = tty_sink
      with_stdout(sink) { build("min_turn_seconds" => 60).turn_finished(42.7) }
      expect(sink.string).to be_empty
    end

    it "ignores a nil elapsed (no turn bracket)" do
      sink = tty_sink
      with_stdout(sink) { build.turn_finished(nil) }
      expect(sink.string).to be_empty
    end
  end

  describe "command hook" do
    it "spawns the command detached with RUBINO_EVENT and RUBINO_MESSAGE in env" do
      allow(Process).to receive(:spawn).and_return(4242)
      allow(Process).to receive(:detach)
      with_stdout(StringIO.new) do
        build("command" => "notify-send rubino").blocked("sa_1 needs you")
      end
      expect(Process).to have_received(:spawn).with(
        { "RUBINO_EVENT" => "blocked", "RUBINO_MESSAGE" => "sa_1 needs you" },
        "notify-send rubino",
        in: File::NULL, out: File::NULL, err: File::NULL
      )
      expect(Process).to have_received(:detach).with(4242)
    end

    it "is not invoked when no command is configured" do
      allow(Process).to receive(:spawn)
      sink = tty_sink
      with_stdout(sink) { build.needs_approval }
      expect(Process).not_to have_received(:spawn)
    end

    it "swallows spawn failures (best-effort) without killing the turn" do
      allow(Process).to receive(:spawn).and_raise(Errno::ENOENT)
      sink = tty_sink
      expect do
        with_stdout(sink) { build("command" => "no-such-binary").needs_approval }
      end.not_to raise_error
      # The bell still rang even though the hook failed.
      expect(sink.string).to include("\a")
    end
  end

  describe "coalescing" do
    before do
      # Pin the channel set: under a real iTerm2 the OSC 9 terminator is a
      # second BEL byte, which would skew the exact \a counts below.
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with("TERM_PROGRAM").and_return(nil)
    end

    it "emits at most one signal per burst window" do
      sink = tty_sink
      with_stdout(sink) do
        notifier = build
        notifier.needs_approval
        notifier.blocked
        notifier.turn_finished(99)
      end
      expect(sink.string.count("\a")).to eq(1)
    end

    it "rings again once the window has passed" do
      sink = tty_sink
      notifier = build
      with_stdout(sink) do
        notifier.needs_approval
        # Rewind the gate instead of sleeping out the real window.
        notifier.instance_variable_set(
          :@last_emitted_at,
          Process.clock_gettime(Process::CLOCK_MONOTONIC) - described_class::COALESCE_SECONDS - 0.1
        )
        notifier.blocked
      end
      expect(sink.string.count("\a")).to eq(2)
    end
  end
end
