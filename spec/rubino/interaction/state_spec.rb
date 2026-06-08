# frozen_string_literal: true

RSpec.describe Rubino::Interaction::State do
  subject(:state) { described_class.new }

  describe "initial state" do
    it "starts as idle" do
      expect(state.current).to eq(:idle)
      expect(state.idle?).to be true
    end
  end

  describe "#transition_to!" do
    it "transitions to a valid state" do
      state.transition_to!(:receiving_input)
      expect(state.current).to eq(:receiving_input)
    end

    it "raises for invalid state" do
      expect {
        state.transition_to!(:bogus)
      }.to raise_error(Rubino::Error)
    end

    # Audit finding (2): streaming_response/executing_tools were listed but
    # never transitioned to by Lifecycle (calling_model -> persisting_session).
    # They have been removed from the timeline.
    it "rejects states the lifecycle never reaches" do
      expect { state.transition_to!(:streaming_response) }
        .to raise_error(Rubino::Error)
      expect { state.transition_to!(:executing_tools) }
        .to raise_error(Rubino::Error)
    end

    it "emits events when event_bus provided" do
      bus = Rubino::Interaction::EventBus.new
      received = []
      bus.on(:status_changed) { |p| received << p }

      state.transition_to!(:loading_session, event_bus: bus)
      expect(received.last).to eq({ from: :idle, to: :loading_session })
    end
  end

  describe "#terminal?" do
    it "returns true for finished" do
      state.transition_to!(:finished)
      expect(state.terminal?).to be true
    end

    it "returns true for failed" do
      state.transition_to!(:failed)
      expect(state.terminal?).to be true
    end

    it "returns false for other states" do
      state.transition_to!(:calling_model)
      expect(state.terminal?).to be false
    end
  end
end
