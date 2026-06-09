# frozen_string_literal: true

require "thor"

module Rubino
  module CLI
    # Subcommands for managing persistent memories
    class MemoryCommand < Thor
      # Clean `tree`/help label instead of the underscored class-name default (F12).
      namespace "rubino memory"

      def self.exit_on_failure?
        true
      end

      desc "list", "List stored memories (live facts only; --all includes superseded)"
      option :kind, type: :string, desc: "Filter by memory kind"
      option :limit, type: :numeric, default: 20, desc: "Max results"
      option :all, type: :boolean, default: false,
                   desc: "Include superseded (soft-retired) facts"
      def list
        Rubino.ensure_database_ready!
        memories = backend_store.list(kind: options[:kind], limit: options[:limit],
                                      include_retired: options[:all])

        if memories.empty?
          Rubino.ui.info("No memories found.")
          return
        end

        rows = memories.map do |m|
          [m[:id][0..7], m[:kind], m[:content][0..60], m[:created_at]]
        end

        Rubino.ui.table(
          headers: %w[ID Kind Content Created],
          rows: rows
        )
      end

      desc "show ID", "Show a specific memory"
      def show(id)
        memory = backend_store.find(id)

        if memory.nil?
          Rubino.ui.error("Memory not found: #{id}")
          return
        end

        Rubino.ui.info("ID: #{memory[:id]}")
        Rubino.ui.info("Kind: #{memory[:kind]}")
        Rubino.ui.info("Confidence: #{memory[:confidence]}")
        Rubino.ui.info("Created: #{memory[:created_at]}")
        # The temporal chain (#88): a soft-retired fact shows when it stopped
        # being true and which fact replaced it.
        if memory[:valid_to]
          Rubino.ui.info("Retired: #{memory[:valid_to]}")
          Rubino.ui.info("Superseded by: #{memory[:superseded_by]}") if memory[:superseded_by]
        end
        Rubino.ui.separator
        Rubino.ui.info(memory[:content])
      end

      desc "delete ID", "Delete a specific memory"
      def delete(id)
        if backend_store.delete(id)
          Rubino.ui.success("Memory deleted: #{id}")
        else
          Rubino.ui.error("Memory not found: #{id}")
        end
      end

      desc "backend [NAME]", "Show the active memory backend, or switch to NAME"
      def backend(name = nil)
        return show_backend if name.nil?

        unless Memory::Backends.registered?(name)
          Rubino.ui.error(
            "Unknown memory backend: #{name}. Available: #{Memory::Backends.names.join(", ")}"
          )
          return
        end

        Config::Writer.new(config_path: config_path).set("memory.backend", name)
        Rubino.ui.success("memory.backend = #{name}")
      end

      private

      # Resolve the *configured* memory backend (default: sqlite tiny-Zep), the
      # same store the agent loop, the in-chat `/memory` view and the HTTP
      # `/v1/memory` ops use. The old `Memory::Store.new` was hardwired to the
      # legacy `:memories` table and ignored `memory.backend`, so list/show/delete
      # never saw the facts the agent actually persists (#94).
      def backend_store
        @backend_store ||= Memory::Backends.build
      end

      def show_backend
        active = Rubino.configuration.dig("memory", "backend") || Memory::Backends::DEFAULT_NAME
        Rubino.ui.info("Active backend: #{active}")
        Rubino.ui.info("Available: #{Memory::Backends.names.join(", ")}")
      end

      def config_path
        Config::Loader.new.config_path
      end
    end
  end
end
