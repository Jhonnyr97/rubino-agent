# frozen_string_literal: true

require "stringio"

# SIGCONT redraw insurance: after ^Z (SIGTSTP) and `fg`, the terminal shows a
# stale screen until the next keystroke. The composer installs a defensive
# SIGCONT trap that re-enters via the same full-redraw path SIGWINCH uses, so
# resume repaints cleanly. The trap must be trap-safe and a no-op with no live
# composer.
RSpec.describe Rubino::UI::BottomComposer do
  # A StringIO that answers #winsize so width math is deterministic.
  let(:term_io) do
    io = StringIO.new
    io.define_singleton_method(:winsize) { [24, 40] }
    io
  end
  let(:queue)  { Rubino::Interaction::InputQueue.new }
  let(:output) { term_io }
  let(:input)  { StringIO.new }

  # Records each #resize call so the trap's effect can be asserted without
  # stubbing a method on the object under test.
  let(:resize_fired) { [] }

  # A composer whose #resize records that it fired.
  let(:composer) do
    c = described_class.new(input_queue: queue, input: input, output: output)
    fired = resize_fired
    c.define_singleton_method(:resize) { fired << true }
    c
  end

  it "exposes the #resize / #redraw the CONT handler routes to" do
    plain = described_class.new(input_queue: queue, input: input, output: output)
    expect(plain).to respond_to(:resize) # public redraw entry (SIGWINCH/SIGCONT)
    expect(plain.respond_to?(:redraw, true)).to be(true) # private redraw helper exists
  end

  it "installs a SIGCONT handler that calls #resize when running" do
    skip "platform without SIGCONT" unless Signal.list.key?("CONT")

    composer.instance_variable_set(:@running, true)
    composer.instance_variable_set(:@suspended, false)
    composer.send(:install_cont_trap)
    begin
      Process.kill("CONT", Process.pid)
      sleep 0.05
    ensure
      composer.send(:restore_cont_trap)
    end
    expect(resize_fired).not_to be_empty
  end

  it "the CONT handler is a NO-OP when no composer is running" do
    skip "platform without SIGCONT" unless Signal.list.key?("CONT")

    composer.instance_variable_set(:@running, false)
    composer.send(:install_cont_trap)
    begin
      Process.kill("CONT", Process.pid)
      sleep 0.05
    ensure
      composer.send(:restore_cont_trap)
    end
    expect(resize_fired).to be_empty
  end
end
