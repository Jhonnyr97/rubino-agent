# frozen_string_literal: true

module Rubino
  module API
    module Operations
      module Mode
        # PUT /v1/mode
        # Body: { "mode": "default" | "plan" | "yolo" }
        #
        # Switches the active mode and emits the same `mode_changed` UI event
        # the CLI fires on `/mode plan`, so any in-flight SSE stream notices.
        #
        # @raise [Rubino::ValidationError] on missing/typo'd mode
        class UpdateOperation
          def self.call(request)
            new.call(request)
          end

          def call(request)
            attrs    = request.validate!(Schemas::UpdateMode)
            previous = Rubino::Modes.current

            begin
              Rubino::Modes.set(attrs[:mode])
            rescue ArgumentError => e
              # Modes.set already rejects unknowns; surface as a 422 the same
              # way validation errors do. The dry-schema enum below normally
              # catches this first; this is just defence in depth for an
              # alternate caller.
              raise ValidationError.new(e.message)
            end

            current = Rubino::Modes.current
            Rubino.ui&.mode_changed(current, previous: previous)

            [200, { mode: current, previous: previous, description: Rubino::Modes.description(current) }]
          end
        end
      end
    end
  end
end
