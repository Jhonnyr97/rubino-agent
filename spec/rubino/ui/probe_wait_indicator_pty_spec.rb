# frozen_string_literal: true

require "pty"
require "tmpdir"
require "fileutils"

# Integration spec for #221: during a synchronous /probe (and /agents probe)
# model-peek the REPL has no live composer, so keystrokes used to smear onto the
# `thinking · …` ticker row (no `❯` to echo into). ProbeWaitIndicator now owns a
# transient bottom composer for the wait: it draws a real `❯`, its reader buffers
# keystrokes, and the thinking ticker paints into the composer's transient row
# (the #169 seam) instead of colliding with input. Anything typed is recovered
# into the next idle prompt's draft via the UI stash.
#
# Driven over a PTY so the composer sees a genuine TTY on both ends; skips
# gracefully when no PTY is available (the automated stand-in for a manual E2E).
RSpec.describe Rubino::UI::ProbeWaitIndicator do
  # The child harness: bracket a fake peek with the indicator, paint a ticker
  # frame into the composer's transient row while the user types, then report
  # the recovered draft and whether cooked mode was restored.
  let(:harness) do
    <<~'RUBY'
      $LOAD_PATH.unshift(File.expand_path("lib", Dir.pwd))
      require "rubino"

      ui = Object.new
      def ui.thinking_started = nil
      def ui.thinking_finished = nil
      def ui.stash_probe_draft(text) = @draft = text
      def ui.draft = @draft

      host = Class.new { include Rubino::UI::ProbeWaitIndicator }.new

      host.probe_thinking_started(ui)
      composer = host.instance_variable_get(:@probe_composer)
      deadline = Time.now + 3
      typed_seen = false
      until Time.now > deadline || typed_seen
        composer&.set_partial("thinking · peeking…")
        typed_seen = composer && composer.buffer.include?("MARKER")
        sleep 0.05
      end
      host.probe_thinking_finished(ui)

      $stdout.puts "DRAFT=#{ui.draft.inspect}"
      $stdout.puts "COOKED=#{($stdin.echo? rescue true)}"
      $stdout.flush
    RUBY
  end

  def pty_available?
    PTY.open do |master, slave|
      master.close
      slave.close
    end
    true
  rescue StandardError
    false
  end

  it "echoes typed input into a composer during the peek and recovers it as the draft" do
    skip "no PTY/TTY available in this environment" unless pty_available?

    harness_file = File.join(Dir.tmpdir, "rubino_probe_harness_#{Process.pid}.rb")
    File.write(harness_file, harness)

    output = (+"").force_encoding(Encoding::UTF_8)
    begin
      PTY.spawn("ruby", harness_file) do |reader, writer, pid|
        sleep 0.4 # let the composer start its raw reader
        writer.write("MARKER")
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
      nil
    ensure
      FileUtils.rm_f(harness_file)
    end

    aggregate_failures do
      # A real `❯` composer was drawn for the wait (input has somewhere to land).
      expect(output).to include(Rubino::UI::BottomComposer::PROMPT)
      # The typed marker was echoed into the composer (not smeared onto the row).
      expect(output).to include("MARKER")
      # The buffered text was recovered into the next prompt's draft (no loss).
      expect(output).to include('DRAFT="MARKER"')
      # Cooked mode restored on teardown (no raw leak).
      expect(output).to include("COOKED=true")
    end
  end
end
