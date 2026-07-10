# frozen_string_literal: true

module Rubino
  module Tools
    # Base class for tool-specific security declarations.
    # Each tool creates its own subclass overriding only what differs
    # from the config.yml-driven defaults.
    #
    #   class EditSecurity < Security
    #     def risk = :medium
    #     def require_read = true
    #   end
    class ToolSecurity
      def initialize(config = Rubino.configuration)
        @config = config
      end

      # Risk level: :low (no confirmation), :medium, :high.
      # Reads default from config.yml: tools.default_risk
      def risk
        @config.dig("tools", "default_risk")&.to_sym || :low
      end

      # Sandbox mode: :strict (enforce workspace boundaries),
      # :none (no filesystem sandbox checks).
      def sandbox
        @config.dig("tools", "workspace_strict") != false ? :strict : :none
      end

      # Whether the tool must have read the target file this session
      # before editing it (read-before-edit gate).
      def require_read = false

      # Whether the tool must have read the target file this session
      # before overwriting it (blind-overwrite gate).
      def require_overwrite_guard = false

      # Whether the tool can widen the workspace on approval
      # (write outside workspace if user approves).
      def allow_widening = false

      def risky? = %i[medium high].include?(risk)
    end
  end
end
