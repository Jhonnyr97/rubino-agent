# frozen_string_literal: true

module Rubino
  module Execution
    # The DEFAULT backend: byte-identical to rubino's historical behaviour.
    # argv is exactly the `["bash", "-o", "pipefail", "-c", command]` that
    # the foreground/background shell paths used inline before the seam
    # existed (#156, #290). No OS sandbox, no wrapping — `writable_roots` is
    # accepted for a uniform signature and ignored.
    class LocalBackend
      def argv(command, writable_roots: []) # rubocop:disable Lint/UnusedMethodArgument
        ["bash", "-o", "pipefail", "-c", command]
      end

      # Local is always available — there is nothing to degrade to.
      def degraded? = false
    end
  end
end
