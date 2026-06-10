# frozen_string_literal: true

module Rubino
  module API
    module Operations
      module Skills
        # PUT /v1/skills/:name
        # Persists the enable/disable flag for a single registered skill.
        #
        # @raise [Rubino::NotFoundError] when no skill is registered under +name+.
        # @raise [Rubino::ValidationError] when the body fails Schemas::ToggleSkill.
        class ToggleOperation
          def self.call(request)
            new.call(request)
          end

          # Accepts an alternate skills registry and state repository for tests.
          def initialize(registry: nil, state_repository: nil)
            @registry = registry || ::Rubino::Skills::Registry.new
            @state_repository = state_repository || ::Rubino::Skills::StateRepository.new
          end

          def call(request)
            name = request.params.fetch("name")
            raise NotFoundError.new("skill", name) unless @registry.find(name)

            attrs = request.validate!(Schemas::ToggleSkill)
            # The shared toggle write path (Skills::Toggle, #188) — the same
            # registry-validated StateRepository write the in-chat
            # `/skills enable|disable` and the `rubino skills` CLI verbs run.
            ::Rubino::Skills::Toggle.set(name, enabled: attrs[:enabled],
                                               registry: @registry,
                                               state_repository: @state_repository)
            [200, { name: name, enabled: attrs[:enabled] }]
          end
        end
      end
    end
  end
end
