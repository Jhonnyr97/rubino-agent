# frozen_string_literal: true

module Rubino
  module Commands
    module Handlers
      # The `/memory` in-chat read/manage view over the *active* memory backend,
      # extracted from Commands::Executor (batch B) — the same store the agent
      # loop, the `rubino memory` CLI (#94) and the HTTP `/v1/memory` ops resolve
      # via `Memory::Backends.build`. The agent's MemoryTool does autonomous
      # writes; this is the human's window into it.
      #
      #   /memory                  → backend + count + recent facts
      #   /memory --all            → recent facts INCLUDING retired, marked (#184)
      #   /memory <query>          → substring search over content
      #   /memory search <query>   → same search, explicit subcommand
      #   /memory show <id>        → one fact in full, with the temporal chain (#184)
      #   /memory forget <id>      → delete a fact
      #   /memory backend          → active + available backends (#184)
      class Memory
        def initialize(ui:)
          @ui = ui
        end

        def handle_memory(arguments)
          args = arguments.to_s.strip

          if args.empty?
            show_memory_summary
          elsif args == "--all"
            show_memory_summary(include_retired: true)
          elsif args.match?(/\Ashow\b/)
            id = args[/\Ashow\s+(\S+)\z/, 1]
            id ? show_memory(id) : @ui.info("Usage: /memory show <id>")
          elsif args.match?(/\Abackend\b/)
            show_memory_backend(args[/\Abackend\s+(\S+)\z/, 1])
          elsif args.match?(/\Aforget\b/)
            id = args[/\Aforget\s+(\S+)\z/, 1]
            id ? forget_memory(id) : @ui.info("Usage: /memory forget <id>")
          elsif args.match?(/\Asearch\b/)
            # `search` is a subcommand token, not a query term (#59): bare
            # `/memory search` falls back to the summary instead of searching
            # for the literal word "search".
            query = args[/\Asearch\s+(.+)\z/, 1]
            query ? search_memory(query) : show_memory_summary
          else
            search_memory(args)
          end
        end

        private

        # `/memory show <id>` (#184): a REAL id lookup (the store resolves the
        # short-id prefix), not a substring search over content — an id used to
        # match nothing. Rendering (incl. the temporal chain: Retired /
        # Superseded by) is shared with the `rubino memory show` CLI verb.
        def show_memory(id)
          memory = memory_backend.find(id)
          if memory.nil?
            @ui.error("no fact with id #{id}.")
            return
          end

          CLI::MemoryCommand.render(memory, ui: @ui)
        end

        # `/memory backend [name]` (#184): shows the active + available
        # backends in-chat. SWITCHING stays CLI-only on purpose: every consumer
        # (the lifecycle's retriever/flusher, the memory tool, this executor)
        # memoizes its built backend, so an in-process flip would leave the live
        # loop writing to the OLD store while /memory reads the new one — a
        # half-applied switch. The CLI verb writes config and a restart applies
        # it everywhere at once.
        def show_memory_backend(name)
          CLI::MemoryCommand.render_active_backend(ui: @ui)
          return unless name

          @ui.info("Switching is CLI-only: run `rubino memory backend #{name}` " \
                   "(a restart applies it to the whole agent).")
        end

        def show_memory_summary(include_retired: false)
          store    = memory_backend
          backend  = Rubino.configuration.dig("memory", "backend") || Rubino::Memory::Backends::DEFAULT_NAME
          @ui.info("backend  #{backend}   ·   #{store.count} facts")

          memories = store.list(limit: 10, include_retired: include_retired)
          if memories.empty?
            @ui.info("No facts stored yet — the agent records them as it learns about you.")
            return
          end

          render_memory_table(memories)
          @ui.info("/memory <query>   ·   /memory show <id>   ·   /memory forget <id>")
        end

        def search_memory(query)
          needle  = query.downcase
          matches = memory_backend.list(limit: 200)
                                  .select { |m| m[:content].to_s.downcase.include?(needle) }
          if matches.empty?
            @ui.info("No facts matching #{query.inspect}.")
            return
          end

          shown = matches.first(20)
          @ui.info(%(#{shown.length} match#{"es" if shown.length != 1} for #{query.inspect}))
          # A targeted search must SHOW the matched fact in full — the list-view's
          # narrow truncation hides exactly the part the user searched for (#85).
          # Print each match's full content, wrapping to the terminal width.
          shown.each { |m| render_memory_match(m) }
          @ui.info("/memory forget <id> to delete one")
        end

        # One searched fact, content shown end-to-end (wrapped, never truncated).
        def render_memory_match(memory)
          head    = "#{memory[:id].to_s[0..7]}  #{memory[:kind]}  "
          content = memory[:content].to_s.gsub(/\s+/, " ").strip
          wrap_skill_line(head, content).each { |line| @ui.info(line) }
        end

        def forget_memory(id)
          store  = memory_backend
          memory = store.find(id)
          if memory.nil?
            @ui.error("no fact with id #{id}.")
            return
          end

          # Destructive, irreversible delete — confirm first, default No (#218).
          # A piped/Esc/EOF decline must NOT forget the fact.
          confirmed = @ui.confirm_destructive(
            %(Forget fact #{memory[:id][0..7]} "#{truncate(memory[:content], 60)}"? This cannot be undone.)
          )
          unless confirmed
            @ui.info("Aborted.")
            return
          end

          store.delete(memory[:id])
          @ui.success(%(Forgot #{memory[:id][0..7]} "#{truncate(memory[:content], 60)}"))
        end

        # Resolve the *configured* memory backend (default: sqlite tiny-Zep), the
        # same store the agent loop, the `rubino memory` CLI and the HTTP
        # `/v1/memory` ops use. The old `Memory::Store.new` was hardwired to the
        # legacy `:memories` table and ignored `memory.backend`, so in-chat
        # `/memory` never saw the facts the agent actually persists (#106).
        def memory_backend
          @memory_backend ||= Rubino::Memory::Backends.build
        end

        # The retired tombstone marker is shared with `rubino memory list --all`
        # (CLI::MemoryCommand.retired_marker) so both surfaces speak one dialect.
        def render_memory_table(memories)
          rows = memories.map do |m|
            [m[:id].to_s[0..7], m[:kind].to_s,
             "#{truncate(m[:content], 60)}#{CLI::MemoryCommand.retired_marker(m)}"]
          end
          @ui.table(headers: %w[ID Kind Content], rows: rows)
        end

        # Wraps "<head><description>" to the terminal width, breaking only on
        # whitespace, with continuation lines indented to the description column.
        def wrap_skill_line(head, description)
          width = terminal_width
          indent = " " * head.length
          avail  = [width - head.length, 20].max

          lines = []
          current = +""
          description.split(/\s+/).each do |word|
            candidate = current.empty? ? word : "#{current} #{word}"
            if candidate.length > avail && !current.empty?
              lines << current
              current = word.dup
            else
              current = candidate
            end
          end
          lines << current unless current.empty?
          lines = [""] if lines.empty?

          lines.each_with_index.map { |line, i| (i.zero? ? head : indent) + line }
        end

        def truncate(text, max)
          s = text.to_s.gsub(/\s+/, " ").strip
          s.length > max ? "#{s[0, max - 1]}…" : s
        end

        def terminal_width
          cols = IO.console&.winsize&.last
          cols&.positive? ? cols : 80
        rescue StandardError
          80
        end
      end
    end
  end
end
