# frozen_string_literal: true

module Rubino
  module Skills
    # ONE enable/disable write path for every surface (#188): the HTTP API
    # toggle (PUT /v1/skills/:name), the in-chat `/skills enable|disable`
    # and the `rubino skills enable|disable` CLI verbs all validate against
    # the registry and persist through the same StateRepository write —
    # previously the API operation was the ONLY caller of StateRepository#set,
    # so a CLI-only user literally could not disable a skill.
    module Toggle
      # Persists the enabled flag for +name+. Returns the registered Skill
      # (state written), or nil when the name is unknown (nothing written) —
      # the caller decides how to surface the miss (404 for the API, a
      # lowercase ✗ line for CLI/chat).
      def self.set(name, enabled:, registry: nil, state_repository: nil)
        registry ||= Registry.new
        skill = registry.find(name)
        return nil unless skill

        (state_repository || StateRepository.new).set(name, enabled: enabled)
        skill
      end
    end
  end
end
