# frozen_string_literal: true

require "pty"
require "io/console"

# HAPPY-PATH end-to-end spec for the composer -> TTY::Prompt approval handoff
# inside a real PTY: a started composer with a typed draft, then
# +BottomComposer.run_in_terminal { TTY::Prompt#select }+ — exactly the wrapper
# CLI#approval_choice uses. It asserts the steady-state contract: once the menu
# owns $stdin, every keystroke reaches the menu (selection lands on the Nth
# item, never one short) and the composer draft survives suspend/resume.
#
# This spec is NOT the regression guard for the #80 reader-teardown race (a
# byte in flight while the raw reader is torn down being swallowed by the dying
# +getc+). That window is a few MICROSECONDS inside #stop_reader and cannot be
# hit by externally-timed PTY input — measured while closing issue #10:
#   - a byte written the instant the harness reaches the handoff (marker
#     printed right before run_in_terminal) lands AFTER the reader is already
#     gone, even on pre-fix kill-based code (20/20 survivals on a revert);
#   - a byte written atomically WITH the triggering Enter is consumed by the
#     still-running reader before suspend on FIXED code too (19/20 eaten) —
#     that is the separate pre-prompt type-ahead window of #10 pt 2, not #80.
# The deterministic #80 guard is the unit spec in bottom_composer_spec.rb
# ("reader teardown handoff (#80)"), which forces the both-ready select wake
# and a scheduled reader at the seam.
#
# Skips gracefully when no PTY/TTY is available, per the no-manual-E2E rule.
RSpec.describe "BottomComposer approval-menu handoff PTY (happy path — NOT the #80 race guard)" do
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
  # SELECTED= marker. The +downs+ arrow-down keystrokes are sent once the menu
  # banner is on screen — the steady state a real user reacts to.
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
        # menu owns stdin — exactly the on-screen state a real user reacts to.
        # The menu's own "arrow to move" banner is the driver's cue to start
        # typing, so every key lands AFTER the handoff completed (see the file
        # header: this deliberately does NOT race the reader teardown).
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
        # exact moment a real user starts pressing keys. Each arrow is sent with
        # a small gap so the menu redraws between keys. NOTE: because we wait
        # for the banner, the reader teardown is long finished — this exercises
        # the happy path only, never the #80 window (see the file header).
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
    # Same discipline as the scroll spec (issue #236): wait for the child's
    # actual EOF/EIO rather than breaking on a 0.5s quiet window, which races
    # the child's post-selection output under load. Deadline = hung-child net.
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 15
    loop do
      chunk = master.read_nonblock(4096)
      buf << chunk.force_encoding(Encoding::UTF_8)
    rescue IO::WaitReadable
      break if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

      IO.select([master], nil, nil, 0.5)
      next
    rescue Errno::EIO, EOFError
      break
    end
    buf
  end

  before { skip "no PTY/TTY available in this environment" unless pty_available? }

  it "delivers every post-handoff key to the menu — three downs reach the deny option" do
    out = select_after_downs(3)
    # From the default :once, three downs must reach the 4th item: :no (deny).
    # Landing one short (:always_tool, an APPROVE) would be the safety failure.
    expect(out).to include("SELECTED=no")
    expect(out).not_to include("SELECTED=always_tool")
  end

  it "delivers a single post-handoff down to the menu (highlight moves off the default)" do
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
