# frozen_string_literal: true

require "tmpdir"
require "fileutils"

# Regression: prod session 31 — model called `puts markitdown_output`
# inside ruby_tool and got back "nil" because evaluate() returned only
# the value of the last expression (puts returns nil). The captured
# stdout was silently dropped. The model then looped retrying for nothing.
RSpec.describe Rubino::Tools::RubyTool do
  subject(:tool) { described_class.new }

  it "has name 'ruby' and :medium risk" do
    expect(tool.name).to eq("ruby")
    expect(tool.risk_level).to eq(:medium)
  end

  it "returns the inspected value of the last expression" do
    out = tool.call("code" => "1 + 2")
    expect(out).to eq("3")
  end

  # Issue #102: the snippet must run rooted at the workspace with the project's
  # lib/ on $LOAD_PATH, so the model can require the code it is working on
  # instead of getting a LoadError and falling back to shell.
  context "with a workspace project on the load path (#102)" do
    around do |example|
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "lib", "my_project"))
        File.write(File.join(dir, "lib", "my_project", "thing.rb"),
                   "module MyProject; ANSWER = 42; end\n")
        @workspace = dir
        example.run
      end
    end

    before do
      cfg = test_configuration("terminal" => { "cwd" => @workspace })
      allow(Rubino).to receive(:configuration).and_return(cfg)
    end

    it "can require a file under the workspace's lib/ and use its constant" do
      out = tool.call("code" => "require 'my_project/thing'; MyProject::ANSWER")
      expect(out).to eq("42")
    end

    it "can require project code via a path relative to the workspace root" do
      out = tool.call("code" => "require './lib/my_project/thing'; MyProject::ANSWER * 2")
      expect(out).to eq("84")
    end

    it "still evaluates plain expressions" do
      out = tool.call("code" => "2 ** 10")
      expect(out).to eq("1024")
    end
  end

  it "annotates the result with captured stdout when the code uses puts" do
    out = tool.call("code" => "puts 'hello from inside'; 42")
    expect(out).to include("42")
    expect(out).to include("--- stdout ---")
    expect(out).to include("hello from inside")
  end

  it "annotates the result with captured stderr separately" do
    out = tool.call("code" => "$stderr.puts 'warn!'; :ok")
    expect(out).to include(":ok")
    expect(out).to include("--- stderr ---")
    expect(out).to include("warn!")
  end

  it "still surfaces stdout when the code only puts (last value is nil)" do
    out = tool.call("code" => "puts 'just a side effect'")
    # Without capture, this used to return literally "nil" — the bug.
    expect(out).to include("just a side effect")
  end

  it "surfaces both stdout AND the error when the code raises after printing" do
    out = tool.call("code" => "puts 'before crash'; raise 'boom'")
    expect(out).to include("RuntimeError")
    expect(out).to include("boom")
    expect(out).to include("before crash")
  end

  it "restores $stdout/$stderr after evaluation" do
    before_out = $stdout
    before_err = $stderr
    tool.call("code" => "puts 'tmp'")
    expect($stdout).to equal(before_out)
    expect($stderr).to equal(before_err)
  end

  # Cooperative cancellation: a flipped CancelToken (chat Ctrl+C / API stop)
  # must interrupt a long eval promptly via the short-tick join loop, instead
  # of blocking until the eval finishes or the full agent_max_turn_seconds
  # timeout elapses. Token is injected by ToolExecutor via Base#cancel_token.
  it "returns promptly (cancelled) when the token is already cancelled" do
    token = Rubino::Interaction::CancelToken.new
    token.cancel!
    tool.cancel_token = token

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    out = tool.call("code" => "sleep 60") # would otherwise hang the suite
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    expect(out).to include("cancelled")
    expect(elapsed).to be < 5 # far below the 60s sleep / configured timeout
  end

  # #328 — a snippet that backgrounds a child (system("... &"), spawn, fork)
  # used to ORPHAN that grandchild on timeout: #terminate killed only the
  # direct child PID. The fix spawns the child in its own process group and
  # signals the WHOLE group (negative PID) on timeout/cancel, mirroring
  # ShellTool, so no descendant survives the call.
  it "kills backgrounded descendants on timeout (no orphans)" do
    skip "POSIX process groups only" if Gem.win_platform?

    Dir.mktmpdir do |dir|
      pidfile = File.join(dir, "child.pid")
      allow(Rubino.configuration).to receive(:agent_max_turn_seconds).and_return(1)

      # Background a long-lived grandchild whose PID we record, then sleep so the
      # PARENT snippet hits the 1s timeout while the grandchild is still alive.
      code = <<~RUBY
        child = spawn("sleep 30")
        Process.detach(child)
        File.write(#{pidfile.dump}, child.to_s)
        $stdout.flush
        sleep 30
      RUBY

      out = tool.call("code" => code)
      expect(out).to include("timed out")

      # Wait for the pidfile then assert the grandchild is gone (signalled via
      # the process group). Poll briefly so the group-kill has a beat to land.
      sleep 0.05 until File.exist?(pidfile) && !File.read(pidfile).strip.empty?
      grandchild = File.read(pidfile).strip.to_i
      expect(grandchild).to be > 0

      alive = nil
      20.times do
        alive = begin
          Process.kill(0, grandchild) # raises ESRCH once it's truly gone
          true
        rescue Errno::ESRCH
          false
        end
        break unless alive

        sleep 0.1
      end

      # Cleanup safeguard so a regression doesn't leak a real sleeper.
      begin
        Process.kill("KILL", grandchild) if alive
      rescue Errno::ESRCH, Errno::EPERM
        nil
      end

      expect(alive).to be(false), "grandchild #{grandchild} survived the ruby tool timeout (orphaned)"
    end
  end
end
