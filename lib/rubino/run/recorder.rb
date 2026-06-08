# frozen_string_literal: true

module Rubino
  module Run
    # Bridges Interaction::EventBus to per-run persisted events. Subscribes
    # to the bus, translates internal symbols to API event names via
    # +EVENT_MAP+, and writes one row per emission through EventStore.
    #
    # +EVENT_MAP+ is the single source of truth for the internal-to-API
    # event-type translation; anything not in the map is dropped on the
    # floor (callers that need to bypass the bus, e.g. +approval.required+
    # / +clarify.required+, must call #emit directly).
    #
    # Lifecycle:
    #   recorder = Recorder.new(run_id:, session_id:)
    #   recorder.attach!
    #   ... run loop ...
    #   recorder.detach!
    class Recorder
      EVENT_MAP = {
        Interaction::Events::MODEL_STREAM         => "message.delta",
        Interaction::Events::MESSAGE_COMPLETED    => "message.completed",
        Interaction::Events::TOOL_STARTED         => "tool.started",
        Interaction::Events::TOOL_PROGRESS        => "tool.progress",
        Interaction::Events::TOOL_FINISHED        => "tool.completed",
        Interaction::Events::ARTIFACT_CREATED     => "artifact.created",
        Interaction::Events::INPUT_INJECTED       => "input.injected",
        Interaction::Events::SKILL_LOADED         => "skill.loaded",
        Interaction::Events::SUBAGENT_SPAWNED     => "subagent.spawned",
        Interaction::Events::SUBAGENT_COMPLETED   => "subagent.completed",
        Interaction::Events::SUBAGENT_FAILED      => "subagent.failed",
        Interaction::Events::INTERACTION_FINISHED => "run.completed",
        Interaction::Events::INTERACTION_FAILED   => "run.failed"
      }.freeze

      def initialize(run_id:, session_id:, event_bus: nil, store: nil)
        @run_id = run_id
        @session_id = session_id
        @event_bus = event_bus || Rubino.event_bus
        @store = store || EventStore.new
        @subscribers = []
      end

      def attach!
        EVENT_MAP.each do |internal_type, api_type|
          handler = ->(payload) { record(api_type, payload) }
          @event_bus.on(internal_type, &handler)
          @subscribers << [internal_type, handler]
        end
      end

      def detach!
        @subscribers.each { |type, _| @event_bus.off(type) }
        @subscribers.clear
      end

      # Direct emission bypassing EventBus (used for API-only events like approval.required).
      def emit(api_type, payload)
        record(api_type, payload)
      end

      private

      def record(api_type, payload)
        @store.append(session_id: @session_id, run_id: @run_id, type: api_type, payload: payload)
      end
    end
  end
end
