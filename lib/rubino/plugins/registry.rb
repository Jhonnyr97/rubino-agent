# frozen_string_literal: true

module Rubino
  module Plugins
    # Central registry for plugins and their hooks.
    class Registry
      def initialize
        @hooks = Hash.new { |h, k| h[k] = [] }
        @plugins = []
      end

      # Registers a hook handler
      def on(event, &block)
        unless HOOKS.include?(event.to_sym)
          raise Error, "Unknown hook: #{event}. Valid: #{HOOKS.join(', ')}"
        end

        @hooks[event.to_sym] << block
      end

      # Executes all handlers for a hook, passing context through each
      def run_hook(event, context = {})
        @hooks[event.to_sym].each do |handler|
          result = handler.call(context)
          # If handler returns a hash, merge it into context
          context = context.merge(result) if result.is_a?(Hash)
        end
        context
      end

      # Returns true if any handlers are registered for this hook
      def has_hook?(event)
        @hooks[event.to_sym].any?
      end

      # Loads a plugin from a file
      def load_plugin(path)
        load(path)
        @plugins << path
      rescue StandardError => e
        Rubino.ui.warning("Failed to load plugin #{path}: #{e.message}")
      end

      # Loads all plugins from configured paths
      def load_all!
        plugin_paths.each do |dir|
          expanded = File.expand_path(dir)
          next unless File.directory?(expanded)

          Dir.glob(File.join(expanded, "*.rb")).each do |path|
            load_plugin(path)
          end
        end
      end

      # Returns count of loaded plugins
      def plugin_count
        @plugins.size
      end

      # Clears all hooks and plugins (for testing)
      def reset!
        @hooks.clear
        @plugins.clear
      end

      private

      def plugin_paths
        [
          ".rubino/plugins",
          "~/.rubino/plugins"
        ]
      end
    end
  end
end
