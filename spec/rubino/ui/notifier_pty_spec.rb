# frozen_string_literal: true

require "pty"
require "fileutils"
require "tmpdir"

# Real-terminal sanity for the attention bell: on a genuine TTY, a LONG turn
# ending must put the audible BEL byte (\a) on the wire, and a QUICK turn must
# not. Run over a PTY so the pipe gate sees a real terminal — the automated
# stand-in for "I heard the bell" (project rule: no manual E2E).
RSpec.describe Rubino::UI::Notifier do
  let(:harness) do
    <<~RUBY
      $LOAD_PATH.unshift(File.expand_path("lib", Dir.pwd))
      require "rubino"

      config = Rubino::Config::Configuration.new(raw: Rubino::Config::Defaults.to_hash)
      ui = Rubino::UI::CLI.new
      ui.instance_variable_set(:@notifier, Rubino::UI::Notifier.new(config: config))

      # A QUICK turn first: must stay silent (the min_turn_seconds gate).
      ui.turn_started
      ui.turn_finished
      $stdout.puts "QUICK_DONE"
      $stdout.flush

      # A LONG turn: rewind the start mark past the 10s threshold instead of
      # sleeping it out.
      ui.turn_started
      ui.instance_variable_set(
        :@turn_started_at,
        Process.clock_gettime(Process::CLOCK_MONOTONIC) - 30
      )
      ui.turn_finished
      $stdout.puts "LONG_DONE"
      $stdout.flush
    RUBY
  end

  def pty_available?
    PTY.open do |m, s|
      m.close
      s.close
    end
    true
  rescue StandardError
    false
  end

  it "rings the BEL byte for a long turn and stays silent for a quick one" do
    skip "no PTY/TTY available in this environment" unless pty_available?

    harness_file = File.join(Dir.tmpdir, "rubino_notifier_harness_#{Process.pid}.rb")
    File.write(harness_file, harness)

    output = (+"").force_encoding(Encoding::UTF_8)
    begin
      PTY.spawn("ruby", harness_file) do |reader, _writer, pid|
        loop do
          chunk = reader.read_nonblock(4096)
          output << chunk.force_encoding(Encoding::UTF_8)
          sleep 0.02
        rescue IO::WaitReadable
          reader.wait_readable(0.3) or next
          retry
        rescue Errno::EIO, EOFError
          break
        end

        Process.wait(pid)
      end
    rescue PTY::ChildExited
      # child finished; output already collected
    ensure
      FileUtils.rm_f(harness_file)
    end

    quick, long = output.split("QUICK_DONE", 2)
    aggregate_failures do
      expect(long).to include("LONG_DONE")
      # The quick turn (everything before its marker) never rang.
      expect(quick).not_to include("\a")
      # The long turn put the audible BEL byte on the wire.
      expect(long).to include("\a")
    end
  end
end
