# frozen_string_literal: true

RSpec.describe Rubino::Interaction::CancelToken do
  subject(:token) { described_class.new }

  it "starts un-cancelled" do
    expect(token.cancelled?).to be false
  end

  it "flips to cancelled after #cancel!" do
    token.cancel!
    expect(token.cancelled?).to be true
  end

  it "#check! is a no-op while un-cancelled" do
    expect { token.check! }.not_to raise_error
  end

  it "#check! raises Rubino::Interrupted after cancellation" do
    token.cancel!
    expect { token.check! }.to raise_error(Rubino::Interrupted)
  end

  it "is safe to cancel from another thread" do
    other = Thread.new { token.cancel! }
    other.join
    expect(token.cancelled?).to be true
  end

  # Regression (root cause of the chat Ctrl+C hang): cancel! runs inside a
  # SIGINT Signal.trap block. Ruby forbids Mutex#lock in a trap context
  # (bug #14222 — "can't be called from trap context"), so when this used a
  # Mutex the trap raised ThreadError, the flag never flipped, and the turn
  # ran on. Must be lock-free / trap-safe.
  # Root-cause regression. cancel! runs inside a real SIGINT trap; a
  # mutex-backed implementation raised ThreadError ("can't be called from
  # trap context", bug #14222) so the flag never flipped. Run in a clean
  # subprocess: the RSpec/SimpleCov harness holds its own mutexes, and a
  # signal delivered into that machinery raises an unrelated ThreadError —
  # a forked, harness-free interpreter isolates the behaviour under test.
  it "#cancel! is callable from inside a Signal.trap('INT') block without raising" do
    script = <<~RUBY
      $LOAD_PATH.unshift("lib")
      module Rubino
        class Error < StandardError; end
        class Interrupted < Error; end
      end
      require "rubino/interaction/cancel_token"
      token  = Rubino::Interaction::CancelToken.new
      raised = nil
      Signal.trap("INT") do
        begin
          token.cancel!
        rescue Exception => e
          raised = e
        end
      end
      Process.kill("INT", Process.pid)
      50.times { break if token.cancelled? || raised; sleep 0.01 }
      print(raised ? "RAISED:\#{raised.class}" : "OK:\#{token.cancelled?}")
    RUBY

    out = IO.popen([RbConfig.ruby, "-e", script], chdir: Dir.pwd, &:read)
    expect(out).to eq("OK:true")
  end

  it "stays cancelled once flipped (one-shot)" do
    token.cancel!
    token.cancel!
    expect(token.cancelled?).to be true
  end

  # Regression #361(b): an EXTERNAL teardown (SIGTERM/SIGHUP from systemd, a
  # terminal close, a supervisor kill) used to unwind via the same
  # Rubino::Interrupted whose message claimed "interrupted by user" — mislabeling
  # a kill the user never issued. The reason now distinguishes the two.
  describe "cancellation reason (#361b)" do
    it "defaults to :user and #check! raises with the user message" do
      token.cancel!
      expect(token.reason).to eq(:user)
      expect { token.check! }.to raise_error(Rubino::Interrupted) do |e|
        expect(e.reason).to eq(:user)
        expect(e.message).to eq("interrupted by user")
      end
    end

    it "records :external and #check! raises with the external-signal message" do
      token.cancel!(reason: :external)
      expect(token.reason).to eq(:external)
      expect { token.check! }.to raise_error(Rubino::Interrupted) do |e|
        expect(e.reason).to eq(:external)
        expect(e.message).to eq("interrupted by external signal")
        expect(e.message).not_to include("user")
      end
    end

    it "is one-shot on the reason too: a later cancel! can't relabel a user interrupt" do
      token.cancel!(reason: :user)
      token.cancel!(reason: :external)
      expect(token.reason).to eq(:user)
    end
  end
end
