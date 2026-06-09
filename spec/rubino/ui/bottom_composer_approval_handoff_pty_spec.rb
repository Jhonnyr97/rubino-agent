# frozen_string_literal: true

require "pty"
require "io/console"

# Regression spec for #80: the interactive approval menu must receive the user's
# VERY FIRST arrow keystroke when the bottom composer hands $stdin over to it.
#
# The bug: BottomComposer's raw reader thread was blocked in a bare +getc+ and
# torn down with +Thread#kill+. A key byte that arrived during the handoff could
# be returned by that dying +getc+ (and swallowed into the composer draft) before
# the kill landed and before TTY::Prompt took over $stdin — so the menu never saw
# the first keystroke. Navigation then landed one item short, which on the
# destructive-command gate could turn an intended DENY into an APPROVE.
#
# This drives the REAL seam end to end inside a PTY: a started composer, then
# +BottomComposer.run_in_terminal { TTY::Prompt#select }+ — exactly the wrapper
# CLI#approval_choice uses. We pre-load the arrow-down bytes into the PTY so they
# are buffered at the OS level at the instant of handoff (the precise condition
# that triggered the race), send N downs + Enter, and assert the menu selected
# the Nth item below the default — i.e. NOT one short. On the pre-fix code the
# first ESC byte was eaten by the dying reader and the selection landed on item
# N-1; with the self-pipe stop the reader exits without a +getc+, leaving every
# byte for the menu.
#
# Skips gracefully when no PTY/TTY is available, per the no-manual-E2E rule.
RSpec.describe "BottomComposer approval-menu handoff PTY (#80)" do
  DOWN = "\e[B" # CSI cursor-down — one arrow-down keystroke

  def pty_available?
    PTY.open do |m, s|
      m.close
      s.close
    end
    true
  rescue StandardError
    false
  end

  # Run a started composer, then open a TTY::Prompt select through
  # run_in_terminal (the real approval wrapper) and print the chosen value as a
  # SELECTED= marker. +downs+ arrow-down keystrokes are buffered into the PTY
  # BEFORE the select starts so they are pending at the handoff — the race
  # condition that dropped the first key.
  def select_after_downs(downs)
    require "tmpdir"
    harness = <<~RUBY
      $LOAD_PATH.unshift(File.expand_path("lib", Dir.pwd))
      require "rubino"
      require "tty-prompt"

      queue    = Rubino::Interaction::InputQueue.new
      composer = Rubino::UI::BottomComposer.new(input_queue: queue)
      composer.start
      # A typed draft must survive the round-trip (handoff must not corrupt it).
      "keep".each_char { |c| composer.handle_key(c) }

      prompt = TTY::Prompt.new
      choice = Rubino::UI::BottomComposer.run_in_terminal do
        # The composer is now suspended (its raw reader stopped + joined) and the
        # menu owns stdin — exactly the on-screen state a real user reacts to. The
        # menu's own "arrow to move" banner is the driver's cue to start typing,
        # so the first arrow lands AFTER the handoff. The only thing that could
        # still drop it is the reader-teardown race (#80): a byte in flight when
        # the reader was torn down. The self-pipe stop closes that window.
        prompt.select("approve?", cycle: false) do |menu|
          menu.choice "yes, once",            :once
          menu.choice "always, this command", :always_command
          menu.choice "always, this tool",    :always_tool
          menu.choice "no — deny this once",  :no
          menu.choice "deny always",          :deny_always
        end
      end

      composer.stop
      $stdout.print("SELECTED=" + choice.to_s + "\\r\\n")
      $stdout.print("DRAFT=" + composer.buffer + "\\r\\n")
      $stdout.flush
    RUBY
    file = File.join(Dir.tmpdir, "rubino_approval_#{Process.pid}_#{rand(1e6).to_i}.rb")
    File.write(file, harness)

    out = (+"").force_encoding(Encoding::UTF_8)
    begin
      PTY.open do |master, slave|
        slave.winsize = [24, 80]
        pid = fork do
          master.close
          $stdin.reopen(slave)
          $stdout.reopen(slave)
          slave.close
          exec("ruby", file)
        end
        slave.close

        # Wait until the MENU itself is on screen (its "arrow to move" banner) —
        # i.e. the composer is already suspended and the menu owns stdin, the
        # exact moment a real user starts pressing keys. Then push the arrows; the
        # first one must not be dropped by the reader-teardown race (#80). Each
        # arrow is sent with a small gap so the menu redraws between keys, matching
        # the issue's repro (which dropped only the FIRST key, at any gap).
        read_until(master, "arrow to move")
        downs.times do
          master.write(DOWN)
          sleep 0.08
        end
        master.write("\r") # commit the selection
        out << read_to_eof(master)
        Process.wait(pid)
      end
    ensure
      File.delete(file) if File.exist?(file)
    end
    out
  end

  def read_until(master, marker)
    buf = +""
    deadline = Time.now + 5
    until buf.include?(marker) || Time.now > deadline
      begin
        chunk = master.read_nonblock(4096)
        buf << chunk.force_encoding(Encoding::UTF_8)
      rescue IO::WaitReadable
        IO.select([master], nil, nil, 0.2)
      rescue Errno::EIO, EOFError
        break
      end
    end
    buf
  end

  def read_to_eof(master)
    buf = (+"").force_encoding(Encoding::UTF_8)
    loop do
      chunk = master.read_nonblock(4096)
      buf << chunk.force_encoding(Encoding::UTF_8)
    rescue IO::WaitReadable
      IO.select([master], nil, nil, 0.5) or break
      next
    rescue Errno::EIO, EOFError
      break
    end
    buf
  end

  before { skip "no PTY/TTY available in this environment" unless pty_available? }

  it "lands on the Nth item (first arrow not dropped) — three downs reach the deny option" do
    out = select_after_downs(3)
    # From the default :once, three downs must reach the 4th item: :no (deny).
    # The pre-fix off-by-one landed on :always_tool (an APPROVE) — the safety bug.
    expect(out).to include("SELECTED=no")
    expect(out).not_to include("SELECTED=always_tool")
  end

  it "lands on the Nth item for a single down (first arrow moves the highlight)" do
    out = select_after_downs(1)
    # One down from :once must reach :always_command, not stay on :once.
    expect(out).to include("SELECTED=always_command")
    expect(out).not_to include("SELECTED=once")
  end

  it "preserves the typed composer draft across the handoff" do
    out = select_after_downs(1)
    expect(out).to include("DRAFT=keep")
  end
end
