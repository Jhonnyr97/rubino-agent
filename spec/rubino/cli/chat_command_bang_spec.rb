# frozen_string_literal: true

# Dispatch wiring for the `!` bang prefix in the interactive REPL: a leading
# `!` routes to Chat::BangShell (no agent turn, no slash dispatch), wins over
# slash dispatch, and a normal line still runs a turn. Driven through the real
# REPL loop on the cooked (non-TTY) input path, like the other chat specs.
RSpec.describe Rubino::CLI::ChatCommand do
  let(:cmd)     { described_class.new({}) }
  let(:db)      { test_database }
  let(:null_ui) { Rubino::UI::Null.new }
  let(:session) { { id: "feedfacecafebeef", title: nil, status: "active", persisted: true } }

  let(:fake_runner) do
    instance_double(Rubino::Agent::Runner,
                    session: session, run: "RESPONSE", run!: "RESPONSE",
                    end_session!: nil, cancel!: nil)
  end

  let(:bang_shell) { instance_double(Rubino::CLI::Chat::BangShell) }

  before do
    allow(Rubino::Agent::Runner).to receive(:new).and_return(fake_runner)
    allow(Rubino).to receive(:database).and_return(db)
    allow(db).to receive(:healthy?).and_return(true)
    allow(Rubino::LLM::CredentialCheck).to receive(:usable?).and_return(true)
    Rubino.ui = null_ui
    allow(Rubino::UI::BottomComposer).to receive(:active?).and_return(false)
    allow(Rubino::CLI::Chat::BangShell).to receive(:new).and_return(bang_shell)
    allow(cmd).to receive(:git_context).and_return(nil)
  end

  def drive(*lines)
    allow(cmd).to receive(:cooked_input).and_return(*(lines + ["/exit"]))
    cmd.execute
  end

  it "routes a `!` line to BangShell instead of running a turn" do
    allow(bang_shell).to receive(:handle).and_return(:ran)

    drive("! git status")

    expect(bang_shell).to have_received(:handle).with("! git status", fake_runner, null_ui)
    expect(fake_runner).not_to have_received(:run)
  end

  it "consumes a bare-`!` usage line without a turn either" do
    allow(bang_shell).to receive(:handle).and_return(:handled)

    drive("!")

    expect(bang_shell).to have_received(:handle).with("!", fake_runner, null_ui)
    expect(fake_runner).not_to have_received(:run)
  end

  it "falls through to a normal agent turn for non-bang input" do
    allow(bang_shell).to receive(:handle).and_return(nil)

    drive("hello agent")

    expect(fake_runner).to have_received(:run)
      .with("hello agent", image_paths: [], input_queue: anything)
  end
end
