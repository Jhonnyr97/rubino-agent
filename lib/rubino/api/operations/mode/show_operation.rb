# frozen_string_literal: true

module Rubino
  module API
    module Operations
      module Mode
        # GET /v1/mode
        # Returns the active mode and the list of valid modes so the web
        # client can render a picker without hardcoding the set.
        class ShowOperation
          def self.call(request)
            new.call(request)
          end

          def call(_request)
            current = Rubino::Modes.current
            [200, {
              mode: current,
              description: Rubino::Modes.description(current),
              available: Rubino::Modes::ALL.map do |m|
                { mode: m, description: Rubino::Modes.description(m) }
              end
            }]
          end
        end
      end
    end
  end
end
