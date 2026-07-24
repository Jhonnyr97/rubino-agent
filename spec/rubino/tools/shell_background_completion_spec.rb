# frozen_string_literal: true

# US-5: a finished BACKGROUND shell must auto-wake the parent the same way a
# finished background subagent does — by pushing a fire-once completion notice
# to the captured background_sink. Before the fix the reader thread just ended
# on EOF and surfaced nothing (lost notification).
RSpec.describe "Background shell completion notification (US-5)" do
  let(:shell) { Rubino::Tools::ShellTool.new }
  let(:registry) { Rubino::Tools::ShellRegistry.instance }

  # Minimal sink: records every notice pushed to it.
  let(:sink) do
    Class.new do
      attr_reader :notices

      def initialize = @notices = []
      def push_notice(text) = @notices << text
    end.new
  end

  before { allow(Rubino).to receive(:background_sink).and_return(sink) }

  it "collapses the home prefix in the user-visible command preview" do
    allow(Dir).to receive(:home).and_return("/Users/example")
    command = "cd /Users/example/AziendaOS && pwd"

    preview = registry.send(:display_command, command)

    expect(preview).to eq("cd ~/AziendaOS && pwd")
    expect(preview).not_to include("/Users/example")
  end

  def wait_for(timeout: 5)
    deadline = Time.now + timeout
    sleep 0.02 until yield || Time.now > deadline
  end

  it "pushes exactly one completion notice when the background shell finishes" do
    start = shell.call("command" => "echo bg_done_marker", "run_in_background" => true)
    run_id = start[/bg_\h+/]
    expect(run_id).not_to be_nil

    wait_for { sink.notices.any? }

    expect(sink.notices.size).to eq(1)
    notice = sink.notices.first
    expect(notice).to include("[background-shell]")
    expect(notice).to include(run_id)
    expect(notice).to include("completed")
    expect(notice).to include("shell_manage run_id=#{run_id} action=output")
  end

  it "reports a non-zero exit in the completion notice" do
    start = shell.call("command" => "exit 3", "run_in_background" => true)
    start[/bg_\h+/]

    wait_for { sink.notices.any? }

    expect(sink.notices.size).to eq(1)
    expect(sink.notices.first).to include("exited (code 3)")
  end

  it "fires the notice at most once even if the reader is drained twice" do
    start = shell.call("command" => "echo once", "run_in_background" => true)
    run_id = start[/bg_\h+/]
    entry = Rubino::Tools::ShellRegistry.instance.find(run_id)
    expect(entry).not_to be_nil

    wait_for { sink.notices.any? }
    # Re-invoke the notifier directly: the fire-once guard must suppress a second push.
    Rubino::Tools::ShellRegistry.instance.send(:notify_completion, entry)

    expect(sink.notices.size).to eq(1)
  end
end
