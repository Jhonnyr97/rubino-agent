# frozen_string_literal: true

module Rubino
  module Interaction
    # Tracks the current state of an interaction.
    # Implements a simple state machine with valid transitions.
    class State
      VALID_STATES = %i[
        idle
        receiving_input
        loading_session
        loading_memory
        building_context
        checking_budget
        compressing_context
        calling_model
        persisting_session
        enqueueing_jobs
        finished
        failed
      ].freeze

      attr_reader :current

      def initialize
        @current = :idle
      end

      # Transitions to a new state, emitting an event
      def transition_to!(new_state, event_bus: nil)
        unless VALID_STATES.include?(new_state)
          raise Error, "Invalid state: #{new_state}"
        end

        old_state = @current
        @current = new_state

        event_bus&.emit(Events::STATUS_CHANGED, from: old_state, to: new_state)
      end

      def idle?
        @current == :idle
      end

      def finished?
        @current == :finished
      end

      def failed?
        @current == :failed
      end

      def terminal?
        finished? || failed?
      end
    end
  end
end
