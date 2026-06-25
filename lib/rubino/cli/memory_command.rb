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

      # Drop Thor's inherited `tree` so its banner doesn't render the doubled
      # "rubino rubino memory tree" (#327); the top-level `rubino tree` covers it.
      remove_command :tree

      desc "list", "List stored memories (live facts only; --all includes superseded)"
      option :kind, type: :string, desc: "Filter by memory kind"
      option :limit, type: :numeric, default: 20, desc: "Max results"
      option :all, type: :boolean, default: false,
                   desc: "Include superseded (soft-retired) facts"
      def list
        guard_corrupt_database!
        Rubino.ensure_database_ready!
        memories = backend_store.list(kind: options[:kind], limit: options[:limit],
                                      include_retired: options[:all])

        if memories.empty?
          # Don't dead-end an empty list (#559): point the user at how memories
          # come to exist (extracted from chat), matching the actionable empty
          # state `sessions list` gives. With a `--kind` filter active the set may
          # just be narrowed, so say so; `--all` surfaces superseded facts.
          hint =
            if options[:kind]
              "No memories found for kind '#{options[:kind]}' (drop --kind to see all)."
            else
              "No memories yet — rubino remembers facts from your chats. " \
                "Start a `rubino chat` and they'll show up here (use --all for superseded ones)."
            end
          Rubino.ui.info(hint)
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

        # Mirror SessionCommand (#20, P2-H1/H2): a not-found is a FAILURE, so
        # raise Thor::Error — exit_on_failure? turns it into a non-zero exit with
        # the message on stderr, so automation can detect the miss and a piped
        # stdout stays clean. ui.error wrote to stdout and returned 0.
        raise Thor::Error, "memory not found: #{id}" if memory.nil?

        self.class.render(memory, ui: Rubino.ui)
      end

      # ONE fact-details rendering for both surfaces (#184): the CLI verb
      # above and the in-chat `/memory show <id>` (Commands::Executor).
      #
      # Memory content (and, defensively, every other stored field) is
      # attacker-influenceable — facts are EXTRACTED from conversation, so a
      # raw `\e]0;…\a` / `\e[2J` in `content` would hijack the window title or
      # clear the screen the moment `info` printed it (CWE-150, R4-N2). As of
      # #564 PrinterBase#puts_colored (the shared funnel) ALSO defangs every row
      # via sanitize_terminal_keep_sgr — which preserves rubino's OWN pastel ANSI
      # (the obstacle that previously kept the funnel from sanitizing) while
      # neutralizing the dangerous bytes. These local #safe calls are now
      # belt-and-suspenders (idempotent) but kept so this surface stays safe
      # independent of the funnel.
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

      desc "delete ID", "Delete a specific memory (alias: forget)"
      def delete(id)
        # Same not-found-is-failure contract as #show (P2-H1/H2): exit non-zero
        # with the error on stderr instead of stdout-printing and returning 0.
        raise Thor::Error, "memory not found: #{id}" unless backend_store.delete(id)

        Rubino.ui.success("Memory deleted: #{id}")
      end

      # Verb parity with the in-chat `/memory forget <id>` (#Y3B): the REPL says
      # "forget", the CLI said only "delete". Both surfaces now accept BOTH verbs
      # so muscle memory from either side works on the other.
      desc "forget ID", "Forget (delete) a specific memory"
      def forget(id)
        delete(id)
      end

      desc "backend [NAME]", "Show the active memory backend, or switch to NAME"
      def backend(name = nil)
        return show_backend if name.nil?

        unless Memory::Backends.registered?(name)
          raise Thor::Error,
                "Unknown memory backend: #{name}. Available: #{Memory::Backends.names.join(", ")}"
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

      # Resolve the *configured* memory backend (default: sqlite), the
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

      # Turn a PRESENT-but-UNUSABLE on-disk DB (corrupt image, or the duplicate
      # `schema_info` rows a concurrent first-boot race leaves, #race) into a
      # clean, actionable diagnostic instead of leaking a raw Sequel/sqlite3
      # backtrace (#333b / #race) — shares one detection with
      # SessionCommand#guard_corrupt_database! via Rubino.database_repair_message.
      # Thor prints a Thor::Error's message to stderr and exits non-zero with no
      # backtrace.
      def guard_corrupt_database!
        message = Rubino.database_repair_message
        raise Thor::Error, message if message
      end
    end
  end
end
