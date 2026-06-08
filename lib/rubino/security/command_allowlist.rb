# frozen_string_literal: true

module Rubino
  module Security
    # Manages a whitelist of shell commands that can be executed without confirmation.
    class CommandAllowlist
      def initialize(config: nil)
        @config = config || Rubino.configuration
        @allowlist = @config.security_command_allowlist
      end

      # Returns true if the command matches an entry in the allowlist.
      # An EMPTY allowlist matches NOTHING — pre-approval is opt-in, so an
      # unconfigured allowlist must never auto-approve everything.
      def allowed?(command)
        return false if @allowlist.empty?

        @allowlist.any? do |allowed|
          command.strip.start_with?(allowed.strip)
        end
      end
    end
  end
end
