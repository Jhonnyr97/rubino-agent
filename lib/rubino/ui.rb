# frozen_string_literal: true

module Rubino
  # UI module namespace and factory.
  # All output in the application flows through a UI adapter.
  module UI
    # Factory method to build the appropriate UI adapter
    def self.build(adapter_name)
      case adapter_name.to_s
      when "cli"
        CLI.new
      when "api"
        API.new
      when "null"
        Null.new
      else
        raise ConfigurationError, "Unknown UI adapter: #{adapter_name}"
      end
    end
  end
end
