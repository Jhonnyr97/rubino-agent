# frozen_string_literal: true

module Rubino
  module CLI
    module Chat
      # Builds the composer's CompletionSource: the `/command` + `@file` candidates
      # plus the per-command ARGUMENT grammars (the dropdown that completes the
      # argument of /skills, /agents, /mcp, /sessions, /memory, /config, … the same
      # way it completes a command or a file). Extracted out of ChatCommand — a
      # self-contained candidate/data-generation block (#17 collaborator pattern).
      #
      # Given the command loader it needs; every source is best-effort (a DB or
      # registry hiccup degrades to no candidates, never a broken prompt) and read
      # lazily on each dropdown open so a /model, /config or skill change is
      # reflected immediately.
      class CompletionBuilder
        # The /agents subcommand grammar offered by the dropdown (#39): first an
        # id, then what you can do to it.
        AGENTS_SUBCOMMANDS = ["steer", "probe", "--stop"].freeze

        # The /mcp subcommand grammar (#182): configured server names + reload
        # first, then the on/off verbs for a named server.
        MCP_SUBCOMMANDS = %w[on off].freeze

        # The /sessions subcommand grammar (#183): verbs + recent session ids
        # first (bare id resumes, verb then id shows/deletes), then ids after a
        # verb. Mirrors the /agents grammar so the picker teaches the surface.
        SESSIONS_SUBCOMMANDS = ["show", "delete", "--all"].freeze

        # The /memory subcommand grammar (#184): verbs first, then recent fact
        # ids after show/forget (short ids — the store resolves prefixes) or the
        # registered backend names after backend.
        MEMORY_SUBCOMMANDS = ["search", "show", "forget", "backend", "--all"].freeze

        # The /skills grammar (#188): position one mixes the `✗ none` clear entry
        # (CompletionSource keeps its special matching), the enable/disable verbs
        # and the activate-by-name skill list; after a toggle verb, the names
        # complete again. Activate-by-name and `✗ none` behave exactly as before.
        SKILLS_SUBCOMMANDS = %w[enable disable].freeze

        # The /config grammar (#187): verbs + the known config keys first (a
        # bare key gets, key+value sets), keys again after get/set.
        CONFIG_SUBCOMMANDS = %w[get set show path].freeze

        def initialize(cmd_loader)
          @cmd_loader = cmd_loader
        end

        def build
          custom = begin
            @cmd_loader.names
          rescue StandardError
            []
          end
          names  = (::Rubino::Commands::BuiltIns::NAMES + agent_command_names + custom).uniq
          files  = -> { Rubino::Workspace.primary_root }
          # ARGUMENT sources: the dropdown completes the argument of these commands
          # the same way it completes `/command` and `@file`.
          #   * /skills <partial> — a skill name (lazily re-read each open so a
          #     freshly-authored skill appears), TRUST-aligned with the prompt
          #     assembler (#63) so the picker never offers a skill that won't pin.
          #   * /agents (alias /tasks) — the live subagent ids, then the
          #     steer/probe/--stop subcommand grammar, so the comm surface is
          #     discoverable from the composer (#39).
          #   * /reply — the ids of children blocked waiting on the human.
          #   * /mcp — the configured server names (+ reload), then on/off for a
          #     named server (#182), same grammar shape as /agents.
          #   * /mode, /reasoning, /think — the closed enums (#185), via the
          #     positional shape so no `✗ none` clear entry is injected (there
          #     is no "clear" for a mode — see CompletionSource#initialize).
          #   * /model — the ruby_llm-registry model ids for the active provider
          #     (empty for custom backends like minimax/gateway, which aren't
          #     enumerable — the dropdown just shows nothing extra there).
          #   * /add-dir — filesystem DIRECTORY candidates from the typed
          #     partial (#185), via the partial-aware two-arg shape.
          #   * /sessions, /memory — verbs + recent ids (#183/#184), the same
          #     per-position grammar /agents ships.
          #   * /jobs — recent job ids (#187); /config — the get/set/show/path
          #     verbs + the known config keys flattened from the defaults tree.
          #   * /skills — the `✗ none` clear entry + the enable/disable verbs +
          #     the skill names (#188); after a toggle verb, the names again.
          Rubino::UI::CompletionSource.new(commands: names, files: files,
                                           arg_sources: arg_sources,
                                           descriptions: completion_descriptions)
        end

        private

        # The per-command ARGUMENT completion sources (#39): the dropdown
        # completes the argument of these commands the same way it completes
        # `/command` and `@file`. See the per-entry notes inline.
        def arg_sources
          {
            "skills" => ->(args) { skills_arg_candidates(args) },
            "agents" => ->(args) { agents_arg_candidates(args) },
            "tasks" => ->(args) { agents_arg_candidates(args) },
            "agent" => ->(args) { args.empty? ? primary_agent_names : [] },
            "reply" => ->(args) { args.empty? ? blocked_subagent_ids : [] },
            "mcp" => ->(args) { mcp_arg_candidates(args) },
            "mode" => ->(args) { args.empty? ? Rubino::Modes::ALL.map(&:to_s) : [] },
            "model" => ->(args) { args.empty? ? model_arg_candidates : [] },
            "reasoning" => ->(args) { args.empty? ? Rubino::Config::ReasoningPrefs::RENDER_MODES.map(&:to_s) : [] },
            "think" => ->(args) { args.empty? ? Rubino::Config::ReasoningPrefs::EFFORTS.map(&:to_s) : [] },
            "add-dir" => lambda { |args, partial|
              args.empty? ? Rubino::UI::CompletionSource.directory_candidates(partial) : []
            },
            "sessions" => ->(args) { sessions_arg_candidates(args) },
            "memory" => ->(args) { memory_arg_candidates(args) },
            "jobs" => ->(args) { args.empty? ? recent_job_ids : [] },
            "config" => ->(args) { config_arg_candidates(args) }
          }
        end

        # Agent slash commands (#320): every visible agent is reachable as a
        # `/<name>` (a bare `/<primary>` switches, `/<name> <msg>` routes one
        # turn). Surfaced in the dropdown alongside the built-ins so they're
        # discoverable; resolved lazily so a freshly registered agent appears.
        def agent_command_names
          ::Rubino.agent_registry.all.reject(&:hidden?).map { |a| "/#{a.name}" }
        rescue StandardError
          []
        end

        # The switchable primary-agent names, for the `/agent <name>` argument.
        def primary_agent_names
          ::Rubino.agent_registry.primary_agents.map(&:name)
        rescue StandardError
          []
        end

        # Describe each `/<name>` agent command so the dropdown explains what
        # switching/routing to it does — primaries switch, subagents run one-shot.
        def merge_agent_descriptions!(descriptions)
          ::Rubino.agent_registry.all.reject(&:hidden?).each do |a|
            verb = a.primary? ? "switch to" : "run one turn as"
            descriptions["/#{a.name}"] = "#{verb} the #{a.name} agent — #{a.description}"
          end
        rescue StandardError
          nil
        end

        # Argument candidates per /agents position: ids → subcommands → nothing.
        def agents_arg_candidates(args)
          case args.length
          when 0 then Tools::BackgroundTasks.instance.list.map(&:id)
          when 1 then AGENTS_SUBCOMMANDS
          else []
          end
        end

        # Children parked on an ask_parent waiting for the human — the ids /reply
        # answers.
        def blocked_subagent_ids
          Tools::BackgroundTasks.instance.awaiting_human.map(&:id)
        end

        # The /model candidates: the registry's model ids for the provider the
        # next turn would route through. Resolved lazily on each dropdown open so
        # a /model or /config provider switch is reflected immediately.
        def model_arg_candidates
          config  = Rubino.configuration
          current = config.model_default
          Rubino::LLM::ModelCatalog.ids_for(
            Rubino::LLM::ProviderResolver.resolve(current, explicit_provider: config.model_provider)
          )
        rescue StandardError
          []
        end

        def mcp_arg_candidates(args)
          case args.length
          when 0 then mcp_server_names + ["reload"]
          when 1 then args.first == "reload" ? [] : MCP_SUBCOMMANDS
          else []
          end
        end

        def mcp_server_names
          (Rubino.configuration.dig("mcp", "servers") || {}).keys.map(&:to_s)
        rescue StandardError
          []
        end

        def sessions_arg_candidates(args)
          case args.length
          when 0 then SESSIONS_SUBCOMMANDS + recent_session_ids
          when 1 then %w[show delete].include?(args.first) ? recent_session_ids : []
          else []
          end
        end

        # Recent session ids for the /sessions dropdown — same source the
        # in-chat list reads (Session::Repository#list). Best-effort: a DB
        # hiccup degrades to no id candidates, never a broken prompt.
        def recent_session_ids
          Rubino::Session::Repository.new.list(limit: 10).map { |s| s[:id].to_s }
        rescue StandardError
          []
        end

        def memory_arg_candidates(args)
          case args.length
          when 0 then MEMORY_SUBCOMMANDS
          when 1
            case args.first
            when "show", "forget" then recent_memory_ids
            when "backend" then Rubino::Memory::Backends.names
            else []
            end
          else []
          end
        end

        # Recent fact ids (short form) for the /memory show/forget dropdown,
        # read from the ACTIVE backend — the same store /memory manages.
        def recent_memory_ids
          Rubino::Memory::Backends.build.list(limit: 10).map { |m| m[:id].to_s[0..7] }
        rescue StandardError
          []
        end

        def skills_arg_candidates(args)
          case args.length
          when 0 then [Rubino::UI::CompletionSource::NONE_ENTRY] + SKILLS_SUBCOMMANDS + skill_names
          when 1 then SKILLS_SUBCOMMANDS.include?(args.first) ? skill_names : []
          else []
          end
        end

        # TRUST-aligned skill names (#63), lazily re-read each open so a
        # freshly-authored skill appears. Best-effort, like the other sources.
        def skill_names
          Rubino::Skills::Registry.trusted.names
        rescue StandardError
          []
        end

        # Recent job ids (the short form the /jobs table renders — the queue
        # resolves prefixes) for the /jobs dropdown (#187).
        def recent_job_ids
          Rubino::Jobs::Queue.new.list(limit: 10).map { |j| j[:id].to_s[0..7] }
        rescue StandardError
          []
        end

        def config_arg_candidates(args)
          case args.length
          when 0 then CONFIG_SUBCOMMANDS + config_key_candidates
          when 1 then %w[get set].include?(args.first) ? config_key_candidates : []
          else []
          end
        end

        # The KNOWN config vocabulary: every leaf dot-path in the defaults tree
        # (Config::Defaults.to_hash) — the same keys `config get` resolves
        # against. Discovery, not validation: a key only present in the user's
        # config.yml still works typed by hand.
        def config_key_candidates
          flatten_config_keys(Rubino::Config::Defaults.to_hash)
        rescue StandardError
          []
        end

        def flatten_config_keys(tree, prefix = nil)
          tree.flat_map do |key, value|
            path = [prefix, key.to_s].compact.join(".")
            value.is_a?(Hash) && !value.empty? ? flatten_config_keys(value, path) : [path]
          end
        end

        # One-line descriptions for the dropdown (#39): the SAME strings /help
        # shows (BuiltIns + custom command frontmatter), plus usage hints for the
        # /agents subcommand grammar. Best-effort — a loader hiccup degrades to
        # built-ins only, never breaks the prompt.
        def completion_descriptions
          descriptions = ::Rubino::Commands::BuiltIns::DESCRIPTIONS.dup
          begin
            @cmd_loader.all.each do |cmd|
              desc = cmd.description.to_s.strip
              descriptions["/#{cmd.name}"] = desc unless desc.empty?
            end
          rescue StandardError
            nil
          end
          merge_agent_descriptions!(descriptions)
          descriptions.merge(
            "steer" => "park a note the subagent folds in at its next turn",
            "probe" => "ask the subagent an ephemeral question (not saved)",
            "--stop" => "cancel the running subagent",
            # /mcp verbs (#182). "off" is ALSO /think's zero effort (#185) —
            # descriptions are keyed by candidate string, so the one line
            # covers both surfaces.
            "reload" => "re-read config.yml and reconnect every MCP server",
            "on" => "(re)start the MCP server and register its tools",
            "off" => "mcp: stop the server and its tools · think: no thinking budget",
            # /sessions + /memory verbs (#183/#184). "show"/"--all" are shared
            # by both grammars — and "show" by /config too (#187) — so each
            # one-liner covers all its surfaces.
            "show" => "show full details (sessions/memory: by id · config: the whole tree)",
            "delete" => "delete a session and its messages (asks to confirm)",
            "search" => "search facts by substring",
            "forget" => "delete a fact by id",
            "backend" => "show the active memory backend",
            "--all" => "list everything (sessions: no row cap · memory: incl. retired)",
            # /config verbs (#187) + /skills toggle verbs (#188).
            "get" => "read one config value (dot-notation, merged over defaults)",
            "set" => "write one config value (persisted to config.yml)",
            "path" => "print the config file path",
            "enable" => "put a skill back in the index (every session)",
            "disable" => "drop a skill from the index (every session, persisted)",
            # The closed enums (#185) reuse the same wording the commands print.
            "default" => Rubino::Modes.description(:default),
            "plan" => Rubino::Modes.description(:plan),
            "yolo" => Rubino::Modes.description(:yolo),
            "hidden" => "show no reasoning (Ctrl-O reveals the last)",
            "collapsed" => "a dim one-line cue; Ctrl-O expands",
            "full" => "the whole reasoning as a dim aside",
            "low" => "small thinking-token budget",
            "medium" => "medium thinking-token budget (default)",
            "high" => "large thinking-token budget"
          )
        end
      end
    end
  end
end
