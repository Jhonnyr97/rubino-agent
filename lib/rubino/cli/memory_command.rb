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
          [m[:id][0..7], m[:kind], "#{m[:content][0..60]}#{self.class.retired_marker(m)}", m[:created_at]]
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
          Rubino.ui.error("memory not found: #{id}")
          return
        end

        self.class.render(memory, ui: Rubino.ui)
      end

      # ONE fact-details rendering for both surfaces (#184): the CLI verb
      # above and the in-chat `/memory show <id>` (Commands::Executor).
      #
      # Memory content (and, defensively, every other stored field) is
      # attacker-influenceable — facts are EXTRACTED from conversation, so a
      # raw `\e]0;…\a` / `\e[2J` in `content` would hijack the window title or
      # clear the screen the moment `info` printed it (CWE-150, R4-N2). The
      # `info`/`success` family does NOT sanitize (PrinterBase#puts_colored is
      # the shared funnel and legitimately receives rubino's OWN pastel ANSI
      # from other callers, e.g. the `/agents` watch view, so it can't strip
      # escapes wholesale). We therefore neutralize the UNTRUSTED CONTENT here,
      # before it is handed to the printer, into visible caret notation.
      def self.render(memory, ui:)
        ui.info("ID: #{safe(memory[:id])}")
        ui.info("Kind: #{safe(memory[:kind])}")
        ui.info("Confidence: #{safe(memory[:confidence])}")
        ui.info("Created: #{safe(memory[:created_at])}")
        # The temporal chain (#88): a soft-retired fact shows when it stopped
        # being true and which fact replaced it.
        if memory[:valid_to]
          ui.info("Retired: #{safe(memory[:valid_to])}")
          ui.info("Superseded by: #{safe(memory[:superseded_by])}") if memory[:superseded_by]
        end
        ui.separator
        ui.info(safe(memory[:content]))
      end

      # Neutralize terminal-control bytes in untrusted stored text to visible
      # caret/<XX> notation (CWE-150). Shared by every memory surface that
      # prints a fact field through the non-sanitizing `info` funnel.
      def self.safe(text)
        Util::Output.sanitize_terminal(text)
      end

      desc "delete ID", "Delete a specific memory"
      def delete(id)
        if backend_store.delete(id)
          Rubino.ui.success("Memory deleted: #{id}")
        else
          Rubino.ui.error("memory not found: #{id}")
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

      # `--all` surfaces soft-retired rows next to live ones; without a flag
      # they were indistinguishable and the supersession chain needed a `show`
      # per id (#161). Marks a tombstone with its retirement date and, when
      # known, the short id of the fact that replaced it. A class method so the
      # in-chat `/memory --all` table (#184) speaks the same dialect.
      def self.retired_marker(memory)
        return "" unless memory[:valid_to]

        marker = " (retired #{memory[:valid_to][0..9]}"
        marker += " → #{memory[:superseded_by][0..7]}" if memory[:superseded_by]
        "#{marker})"
      end

      # ONE backend summary for both surfaces (#184): the CLI `memory backend`
      # verb and the in-chat `/memory backend`.
      def self.render_active_backend(ui:)
        active = Rubino.configuration.dig("memory", "backend") || Memory::Backends::DEFAULT_NAME
        ui.info("Active backend: #{active}")
        ui.info("Available: #{Memory::Backends.names.join(", ")}")
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
        self.class.render_active_backend(ui: Rubino.ui)
      end

      def config_path
        Config::Loader.new.config_path
      end
    end
  end
end
