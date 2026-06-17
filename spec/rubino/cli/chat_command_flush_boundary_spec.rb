# frozen_string_literal: true

# RubyLLM is required lazily by the adapter, but spec_helper's global before
# hook touches RubyLLM.configure to null provider bases (so no spec pollutes
# the next). When THIS file runs in isolation nothing has triggered the lazy
# require yet, so load it up front — matching the other LLM specs.
require "ruby_llm"

# Regression for #471: flush_parent_memory! is the OUTERMOST best-effort
# boundary on the rewind/branch path — its contract is "a flush failure must
# NEVER break the branch". A `rescue StandardError` honoured that only for
# StandardError subclasses; some Ruby errors descend directly from Exception
# (e.g. WebMock::NetConnectNotAllowedError) and ESCAPED the guard, propagating
# out and breaking the rewind. The boundary now rescues broadly (Exception)
# while still re-raising genuinely-fatal / control-flow exceptions.
RSpec.describe Rubino::CLI::ChatCommand do
  subject(:cmd) { described_class.new(provider: "fake", model: "fake/test") }

  # auto_extract ON so flush_parent_memory! actually reaches the flusher (the
  # `return unless memory_auto_extract?` guard is not short-circuited).
  let(:config) { test_configuration("memory" => { "auto_extract" => true }) }
  let(:flusher) { instance_double(Rubino::Memory::Flusher) }

  before do
    allow(Rubino).to receive(:configuration).and_return(config)
    allow(Rubino::Memory::Flusher).to receive(:new).and_return(flusher)
    allow(Rubino.logger).to receive(:warn)
  end

  describe "#flush_parent_memory! (best-effort boundary, #471)" do
    # A non-StandardError raised by the aux flush (the real-world example is
    # WebMock::NetConnectNotAllowedError < Exception) must be SWALLOWED so the
    # rewind/branch survives — proving the old `rescue StandardError` gap is
    # closed.
    it "swallows a NON-StandardError raised by the flush (does not propagate)" do
      non_std = Class.new(Exception) # rubocop:disable Lint/InheritException -- mirrors WebMock::NetConnectNotAllowedError, deliberately < Exception
      allow(flusher).to receive(:flush_before_compaction!).and_raise(non_std.new("blocked net connect"))

      expect { cmd.send(:flush_parent_memory!, "parent-1") }.not_to raise_error
      expect(Rubino.logger).to have_received(:warn)
        .with(hash_including(event: "branch.parent_flush_failed"))
    end

    # The other direction: a genuinely-fatal / control-flow exception MUST still
    # propagate — proving we did not over-swallow into a process-wedging
    # rescue Exception.
    it "still propagates a control-flow exception (Interrupt)" do
      allow(flusher).to receive(:flush_before_compaction!).and_raise(Interrupt.new)

      expect { cmd.send(:flush_parent_memory!, "parent-1") }.to raise_error(Interrupt)
    end

    it "still propagates SystemExit" do
      allow(flusher).to receive(:flush_before_compaction!).and_raise(SystemExit.new)

      expect { cmd.send(:flush_parent_memory!, "parent-1") }.to raise_error(SystemExit)
    end
  end
end
