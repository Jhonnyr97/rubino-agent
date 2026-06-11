# frozen_string_literal: true

module Rubino
  module Commands
    module Handlers
      # The `/status` at-a-glance state panel, extracted from Commands::Executor
      # (batch B). Assembles the model/mode/session lines plus approval policy,
      # provider/connection, and the tool/mcp/memory/skills rosters over the same
      # services (Modes, Session::Repository, Memory backend, BackgroundTasks,
      # Skills::Registry). A plain collaborator given the live `ui`/`runner`.
      class Status
        def initialize(ui:, runner:)
          @ui = ui
          @runner = runner
        end

        # Labels dim, values plain, cyan only on the actionable pointers (P8).
        def show_status
          @ui.separator
          @ui.panel_line("model", status_model)
          @ui.panel_line("provider", status_provider_line)
          @ui.panel_line("mode", "#{Rubino::Modes.current} — #{Rubino::Modes.description}")
          @ui.panel_line("display", status_display_line, pointer: "(use /reasoning · /think)")
          @ui.panel_line("approvals", status_approvals_line)
          @ui.panel_line("session", status_session_line)
          @ui.panel_line("tools", status_tools_line)
          # MCP only when servers are configured (#182/#186) — a non-MCP user's
          # /status stays exactly as before, and MCP tools stop being invisibly
          # mixed into the truncated tools line as the only trace of MCP.
          @ui.panel_line("mcp", status_mcp_line, pointer: "(use /mcp)") if Rubino::MCP.enabled?
          if (dirs = status_dirs_line)
            @ui.panel_line("dirs", dirs, pointer: "(use /dirs)")
          end
          @ui.panel_line("memory", status_memory_line, pointer: "(use /memory)")
          @ui.panel_line("skills", status_skills_line, pointer: "(use /skills)")
          @ui.panel_line("background", status_background_line, pointer: "(use /agents)")
          if (jobs = status_jobs_line)
            @ui.panel_line("jobs", jobs, pointer: "(use /jobs)")
          end
          @ui.separator
        end

        private

        # The persisted display prefs (#186): /reasoning and /think write config
        # but were invisible — not in the chip, not in /status.
        def status_display_line
          mode   = Rubino::Config::ReasoningPrefs.mode(Rubino.configuration)
          effort = Rubino::Config::ReasoningPrefs.effort(Rubino.configuration) ||
                   Rubino::Config::ReasoningPrefs::DEFAULT_EFFORT
          "reasoning: #{mode} · effort: #{effort}"
        rescue StandardError
          "(unavailable)"
        end

        # Workspace roots + trust (#186) — trust is the #1 "why are my
        # skills/AGENTS.md not loading" confusion. Only earns a line when there
        # is something to say (>1 root or any untrusted); nil otherwise.
        def status_dirs_line
          roots     = Rubino::Workspace.canonical_roots
          untrusted = roots.count { |d| !Rubino::Trust.trusted?(d) }
          return nil if roots.size <= 1 && untrusted.zero?

          line = "#{roots.size} root#{"s" if roots.size != 1}"
          untrusted.positive? ? "#{line} · #{untrusted} untrusted (context/skills withheld)" : line
        rescue StandardError
          nil
        end

        # The persistent jobs queue (#186) — distinct from the in-process
        # `background` subagents line. Only earns a line when nonzero; nil (no
        # line) when the queue is empty or unreadable.
        def status_jobs_line
          queue   = Rubino::Jobs::Queue.new
          pending = queue.pending_count
          failed  = queue.failed_count
          return nil unless pending.positive? || failed.positive?

          [("#{pending} pending" if pending.positive?),
           ("#{failed} failed" if failed.positive?)].compact.join(" · ")
        rescue StandardError
          nil
        end

        def status_model
          @runner&.session&.dig(:model) ||
            (@runner.respond_to?(:model_id) ? @runner.model_id : nil) ||
            Rubino.configuration.model_default
        end

        # The configured provider — the "what am I talking to" line a status
        # check wants. We report the configured target, not a live probe (a
        # health round-trip would make /status slow and flaky).
        def status_provider_line
          Rubino.configuration.model_provider || "(default)"
        rescue StandardError
          "(unavailable)"
        end

        # One-line approval-policy summary so a newcomer knows what will prompt.
        # Mode is authoritative: yolo skips every approval, plan filters mutating
        # tools out entirely; otherwise approvals come from config.
        def status_approvals_line
          case Rubino::Modes.current
          when :yolo then "skipped (yolo mode — nothing prompts)"
          when :plan then "read-only mode — no edits/shell to approve"
          else            "from config (mutating commands prompt)"
          end
        end

        # A compact roster of the tools the agent can actually use right now
        # (mode filters the registry), so /status answers "what can it DO".
        def status_tools_line
          names = Tools::Registry.instance.enabled_tools.map(&:name).sort
          return "(none)" if names.empty?

          truncate(names.join(", "), 64)
        rescue StandardError
          "(unavailable)"
        end

        # `2 servers · 1 reachable · 14 tools` — reads the LIVE booted manager
        # (no client → 0 reachable), never re-spawns servers.
        def status_mcp_line
          servers   = mcp_servers_config.size
          reachable = mcp_health.count { |h| h[:alive] }
          tools     = Tools::Registry.all.count { |t| t.is_a?(Rubino::MCP::MCPToolWrapper) }
          "#{servers} server#{"s" if servers != 1} · #{reachable} reachable · #{tools} tool#{"s" if tools != 1}"
        rescue StandardError
          "(unavailable)"
        end

        def status_session_line
          session = @runner&.session
          return "(none)" unless session

          id    = session[:id].to_s[0..7]
          title = session[:title].to_s.strip
          title = title.empty? ? "(untitled)" : %("#{title}")
          msgs  = status_message_count(session)
          "#{id}  #{title}#{" · #{msgs} msgs" if msgs}"
        end

        # The session's message count, read LIVE from the message store. The
        # in-memory session hash's :message_count is a boot-time snapshot the
        # streaming path never refreshes, so /status reported a permanent
        # "0 msgs" while the DB had every turn (#159). Counting the persisted
        # rows also matches the "Loaded N prior messages" resume banner.
        def status_message_count(session)
          Session::Store.new.count(session[:id])
        rescue StandardError
          session[:message_count]
        end

        # /status must count facts on the ACTIVE backend — the same store /memory
        # and the `rubino memory` CLI read via Memory::Backends.build — not the
        # legacy `:memories` table Memory::Store is hardwired to (#83).
        def status_memory_line
          backend = Rubino.configuration.dig("memory", "backend") || Rubino::Memory::Backends::DEFAULT_NAME
          "backend: #{backend} · #{memory_backend.count} facts"
        rescue StandardError
          "(unavailable)"
        end

        def status_skills_line
          registry = Rubino::Skills::Registry.trusted
          all      = registry.all
          enabled  = all.count { |s| registry.enabled?(s.name) }
          line     = "#{all.size} available, #{enabled} enabled"
          # WHICH skill is pinned (#186) — the chip shows it but the canonical
          # state dump omitted it.
          active = Rubino::ActiveSkill.current
          active ? "#{line} · active: #{active}" : line
        rescue StandardError
          "(unavailable)"
        end

        def status_background_line
          entries = Tools::BackgroundTasks.instance.list
          running = entries.count { |e| e.status == :running }
          ids     = entries.first(3).map(&:id).join(", ")
          line    = "#{running} running · #{entries.size} total"
          ids.empty? ? line : "#{line} (#{ids})"
        rescue StandardError
          "(unavailable)"
        end

        # Resolve the *configured* memory backend (default: sqlite tiny-Zep) for
        # the fact count — the same store the agent loop and /memory read.
        def memory_backend
          @memory_backend ||= Rubino::Memory::Backends.build
        end

        # The configured mcp.servers block (name => config), {} when absent.
        def mcp_servers_config
          Rubino.configuration.dig("mcp", "servers") || {}
        end

        # Live reachability from the booted manager; [] when MCP never booted.
        def mcp_health
          Rubino::MCP.manager&.health_check || []
        end

        def truncate(text, max)
          s = text.to_s.gsub(/\s+/, " ").strip
          s.length > max ? "#{s[0, max - 1]}…" : s
        end
      end
    end
  end
end
