# frozen_string_literal: true

require "pty"

# Integration spec for the real raw keystroke reader, driven over a PTY so the
# composer sees a genuine TTY on both ends. We spawn a tiny harness that runs a
# BottomComposer with a background thread printing output, type characters into
# the master side while the output streams, then submit a line and assert it was
# pushed to the InputQueue and committed to scrollback — and that the terminal
# is restored to cooked mode on exit.
#
# Skips gracefully when no PTY/TTY is available (CI without a controlling
# terminal), per the project rule against manual E2E: this is the automated
# stand-in.
RSpec.describe "BottomComposer PTY integration" do
  # The harness: starts a composer, runs a background printer for a moment,
  # reads keystrokes, and on submit prints a marker line we can grep, then exits
  # and reports whether stdin is back in cooked mode.
  HARNESS = <<~'RUBY'
    $LOAD_PATH.unshift(File.expand_path("lib", Dir.pwd))
    require "rubino"

    queue    = Rubino::Interaction::InputQueue.new
    composer = Rubino::UI::BottomComposer.new(input_queue: queue)

    # Background "agent": stream a couple of lines above the prompt via the
    # composer while the user types.
    printer = Thread.new do
      3.times do |i|
        sleep 0.15
        composer.print_above("agent chunk #{i}")
      end
    end

    composer.start

    # Wait until the user submits one line (pushed by the reader thread), or
    # time out so the test never hangs.
    deadline = Time.now + 5
    line = nil
    until line || Time.now > deadline
      drained = queue.drain
      line = drained.first unless drained.empty?
      sleep 0.02
    end

    printer.join
    composer.stop

    # Report results on the (now cooked) tty so the master side can read them.
    # In cooked mode terminal echo is back on; raw mode turns it off — so
    # echo? is a reliable "are we cooked again?" probe.
    cooked = ($stdin.echo? rescue true)
    $stdout.puts "SUBMITTED=#{line.inspect}"
    $stdout.puts "COOKED=#{cooked}"
    $stdout.flush
  RUBY

  def pty_available?
    PTY.open do |m, s|
      m.close
      s.close
    end
    true
  rescue StandardError
    false
  end

  it "captures typed input over a PTY, pushes it to the queue, and restores cooked mode" do
    skip "no PTY/TTY available in this environment" unless pty_available?

    require "tmpdir"
    harness_file = File.join(Dir.tmpdir, "rubino_composer_harness_#{Process.pid}.rb")
    File.write(harness_file, HARNESS)

    output = (+"").force_encoding(Encoding::UTF_8)
    begin
      PTY.spawn("ruby", harness_file) do |reader, writer, pid|
        # Give the composer a moment to start its raw reader, then type a line
        # while the background printer is still streaming output above it.
        sleep 0.2
        writer.write("hello agent")
        sleep 0.1
        writer.write("\r") # submit

        loop do
          chunk = reader.read_nonblock(4096)
          output << chunk.force_encoding(Encoding::UTF_8)
          sleep 0.02
        rescue IO::WaitReadable
          IO.select([reader], nil, nil, 0.3) or next
          retry
        rescue Errno::EIO, EOFError
          break
        end

        Process.wait(pid)
      end
    rescue PTY::ChildExited
      # child finished; output already collected
    ensure
      File.delete(harness_file) if File.exist?(harness_file)
    end

    aggregate_failures do
      # The typed line round-tripped through the raw reader into the InputQueue.
      expect(output).to include('SUBMITTED="hello agent"')
      # Cooked mode was restored on teardown (no raw leak).
      expect(output).to include("COOKED=true")
      # Output streamed ABOVE the prompt into scrollback while typing.
      expect(output).to include("agent chunk")
      # The prompt caret was drawn.
      expect(output).to include(Rubino::UI::BottomComposer::PROMPT)
      # TUI-3: the composer ENABLES bracketed-paste mode on start (\e[?2004h),
      # so a real terminal wraps a multi-line paste in \e[200~…\e[201~ markers
      # the reader assembles into ONE input — instead of each newline firing as
      # a separate Enter (N split turns). Without this the paste explodes into
      # many turns/queued items (the unfixed behavior).
      expect(output).to include("\e[?2004h")
      # And disables it on teardown so the mode never leaks past the turn.
      expect(output).to include("\e[?2004l")
    end
  end

  # TUI-3: a multi-line bracketed paste arriving over the REAL raw reader must
  # land as ONE input block (newlines literal in the buffer), not N submitted
  # lines. We feed the \e[200~…\e[201~ wrapper the terminal sends for a paste,
  # then submit, and assert exactly ONE queued item carrying every line.
  PASTE_HARNESS = <<~'RUBY'
    $LOAD_PATH.unshift(File.expand_path("lib", Dir.pwd))
    require "rubino"

    queue    = Rubino::Interaction::InputQueue.new
    composer = Rubino::UI::BottomComposer.new(input_queue: queue)
    composer.start

    deadline = Time.now + 5
    line = nil
    until line || Time.now > deadline
      drained = queue.drain
      line = drained.first unless drained.empty?
      sleep 0.02
    end
    composer.stop

    $stdout.puts "LINE=#{line.inspect}"
    $stdout.puts "NEWLINES=#{line.to_s.count("\n")}"
    $stdout.flush
  RUBY

  it "assembles a multi-line bracketed paste into ONE input, not N turns (TUI-3)" do
    skip "no PTY/TTY available in this environment" unless pty_available?

    require "tmpdir"
    harness_file = File.join(Dir.tmpdir, "rubino_paste_harness_#{Process.pid}.rb")
    File.write(harness_file, PASTE_HARNESS)

    output = (+"").force_encoding(Encoding::UTF_8)
    begin
      PTY.spawn("ruby", harness_file) do |reader, writer, pid|
        sleep 0.3
        # Exactly what a terminal in bracketed-paste mode sends for a 3-line
        # paste: the 200~ opener, the body with literal newlines, the 201~
        # closer. The newlines inside must NOT submit.
        writer.write("\e[200~alpha\nbeta\ngamma\e[201~")
        sleep 0.1
        writer.write("\r") # one submit AFTER the whole paste is assembled

        loop do
          chunk = reader.read_nonblock(4096)
          output << chunk.force_encoding(Encoding::UTF_8)
          sleep 0.02
        rescue IO::WaitReadable
          IO.select([reader], nil, nil, 0.3) or next
          retry
        rescue Errno::EIO, EOFError
          break
        end

        Process.wait(pid)
      end
    rescue PTY::ChildExited
      nil
    ensure
      File.delete(harness_file) if File.exist?(harness_file)
    end

    aggregate_failures do
      # ONE queued line carrying all three pasted lines with their newlines.
      expect(output).to include('LINE="alpha\nbeta\ngamma"')
      expect(output).to include("NEWLINES=2")
    end
  end
end
