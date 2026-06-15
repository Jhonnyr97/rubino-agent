# frozen_string_literal: true

# #389 (residual of #378) — the external-teardown (SIGHUP/SIGTERM) trap was
# wired ONLY into the interactive REPL (install_session_end_traps). The headless
# one-shot path installed only the cooperative SIGINT trap, so a SIGTERM during a
# `rubino -q`/`prompt` run fell through as a bare SignalException — which
# oneshot_external_interrupt? treats as a user Ctrl-C — mislabeling a
# systemd/operator kill as "interrupted by user".
#
# The fix arms the SAME external trap in the one-shot path (without exit(0)) so a
# SIGTERM flips cancel!(reason: :external) and the in-flight turn unwinds via a
# Rubino::Interrupted(reason: :external), labeled "interrupted by external
# signal". SIGINT stays a user interrupt. This spec is OFFLINE: instead of
# delivering a real signal, it captures the TERM handler the one-shot installs
# WHILE run! is "in flight" and invokes it directly, asserting it flips the
# external reason — and that SIGINT still flips a plain (user) cancel.
RSpec.describe Rubino::CLI::ChatCommand do
  let(:db)      { test_database }
  let(:null_ui) { Rubino::UI::Null.new }

  before do
    allow(Rubino).to receive(:database).and_return(db)
    allow(Rubino::LLM::CredentialCheck).to receive(:usable?).and_return(true)
    Rubino.ui = null_ui
  end

  # Drives a one-shot turn whose run! body captures the TERM/INT handlers that
  # are live AT THAT MOMENT (i.e. installed by the one-shot trap wiring), then
  # returns normally so the run completes without a real signal.
  def capture_traps_during_oneshot
    runner = instance_double(Rubino::Agent::Runner)
    allow(Rubino::Agent::Runner).to receive(:new).and_return(runner)
    allow(runner).to receive(:cancel!)
    allow(runner).to receive(:session).and_return({ id: "s1", model: "fake-model" })
    # The headless one-shot now ends its session on completion (ONESHOT-ACTIVE);
    # this spec's run! stub returns normally, so execute reaches end_session!.
    # Stub it on the double so the post-run lifecycle doesn't raise here.
    allow(runner).to receive(:end_session!)

    captured = {}
    allow(runner).to receive(:run!) do
      # Snapshot the handlers currently armed for INT and TERM. Re-trapping with
      # a no-op returns the PREVIOUS (currently-installed) handler, which we
      # immediately restore so we don't disturb the run's own teardown.
      %w[INT TERM HUP].each do |sig|
        next unless Signal.list.key?(sig)

        prev = Signal.trap(sig, "DEFAULT")
        captured[sig] = prev
        Signal.trap(sig, prev || "DEFAULT")
      end
      "done"
    end

    capture_stderr { described_class.new("query" => "hi").execute }
    [runner, captured]
  end

  def capture_stderr
    orig = $stderr
    $stderr = StringIO.new
    yield
    $stderr.string
  ensure
    $stderr = orig
  end

  it "arms a SIGTERM trap during a one-shot run that flips cancel!(reason: :external)" do
    runner, traps = capture_traps_during_oneshot
    term = traps["TERM"]
    expect(term).to respond_to(:call), "expected the one-shot path to install a SIGTERM handler"

    # Invoking the installed TERM handler must flip the EXTERNAL reason (so a
    # real SIGTERM would unwind as Rubino::Interrupted(reason: :external) and be
    # labeled "interrupted by external signal"), NOT a plain user cancel.
    term.call("TERM")
    expect(runner).to have_received(:cancel!).with(reason: :external)
  end

  it "keeps the SIGINT trap a plain (user) cancel — not external" do
    runner, traps = capture_traps_during_oneshot
    int = traps["INT"]
    expect(int).to respond_to(:call), "expected the one-shot path to install a SIGINT handler"

    int.call("INT")
    # The INT handler flips a bare cancel! (no reason) → stays a USER interrupt.
    expect(runner).to have_received(:cancel!).with(no_args)
    expect(runner).not_to have_received(:cancel!).with(reason: :external)
  end
end
