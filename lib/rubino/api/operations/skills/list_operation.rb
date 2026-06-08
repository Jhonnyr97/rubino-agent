# frozen_string_literal: true

module Rubino
  module API
    module Operations
      module Skills
        # GET /v1/skills
        # Lists every registered skill annotated with its persisted enabled flag.
        class ListOperation
          def self.call(request)
            new.call(request)
          end

          # Accepts an alternate skills registry and state repository for tests.
          def initialize(registry: nil, state_repository: nil)
            @registry = registry || ::Rubino::Skills::Registry.new
            @state_repository = state_repository || ::Rubino::Skills::StateRepository.new
          end

          def call(_request)
            skills = @registry.all.map do |skill|
              {
                name: skill.name,
                description: skill.description,
                enabled: @state_repository.enabled?(skill.name)
              }
            end
            [200, skills]
          end
        end
      end
    end
  end
end
