# frozen_string_literal: true

require "yaml"

module Rubino
  module LLM
    # Loads a fake-provider scenario YAML by name and returns the parsed
    # event list. The fake provider drives a deterministic chunk/tool-call
    # stream from these events so the UI and tool plumbing can be exercised
    # without burning provider tokens.
    #
    # Search order:
    #   1. <Rubino.configuration.fake_scenarios_dir>/<name>.yml
    #   2. <gem_root>/lib/rubino/llm/scenarios/<name>.yml
    #
    # The YAML file must contain a top-level `events:` key with an array
    # of event hashes — see scenarios/happy-path.yml for the shape.
    class ScenarioLoader
      class NotFound < Rubino::Error; end

      DEFAULT_DIR = File.expand_path("scenarios", __dir__)

      def self.load(name, scenarios_dir: nil)
        new(scenarios_dir: scenarios_dir).load(name)
      end

      def initialize(scenarios_dir: nil)
        @scenarios_dir = scenarios_dir || configured_dir
      end

      # Returns the array of event hashes under the YAML `events:` key.
      # Raises NotFound when the scenario can't be located under either
      # path, citing both so the operator can fix the misconfiguration.
      def load(name)
        path = resolve_path(name)
        raise NotFound, build_not_found_message(name) unless path

        data = YAML.safe_load_file(path, permitted_classes: [Symbol], aliases: true) || {}
        Array(data["events"] || data[:events])
      end

      private

      def resolve_path(name)
        filename = "#{name}.yml"
        [@scenarios_dir, DEFAULT_DIR].compact.uniq.each do |dir|
          candidate = File.join(dir, filename)
          return candidate if File.file?(candidate)
        end
        nil
      end

      def configured_dir
        cfg = Rubino.configuration
        return nil unless cfg.respond_to?(:dig)

        cfg.dig("fake_provider", "scenarios_dir") || cfg.dig("providers", "fake", "scenarios_dir")
      rescue StandardError
        nil
      end

      def build_not_found_message(name)
        tried = [@scenarios_dir, DEFAULT_DIR].compact.uniq.map { |d| File.join(d, "#{name}.yml") }
        "fake scenario '#{name}' not found. Tried:\n  #{tried.join("\n  ")}"
      end
    end
  end
end
