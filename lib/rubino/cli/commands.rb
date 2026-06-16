# frozen_string_literal: true

require "thor"
require "json"

module Rubino
  module CLI
    # Main Thor command class. All subcommands are registered here.
    class Commands < Thor
      # Without an explicit namespace, Thor's `tree` command derives one by
      # underscoring the class name — "Rubino::CLI::Commands" becomes the
      # mangled "rubino:c_l_i:commands" (the CLI acronym splits into
      # c_l_i) (F12/F14). Pin a clean label instead.
      namespace "rubino"

      def self.exit_on_failure?
        true
      end

      # One-line description of what rubino IS, surfaced as a top-line tagline in
      # `rubino --help` / `rubino help` — Thor's stock command list opens cold
      # with "Commands:" and never says what the tool does or where to start
      # (F-help). Wrap Thor's #help to print a tagline above the listing and a
      # "Getting started: run `rubino setup`" hint below it, so a brand-new user
      # lands on the first action instead of a bare verb table.
      TAGLINE = "rubino — an AI coding agent that reads, edits, and runs code."
      GETTING_STARTED = "Getting started: run `rubino setup` to configure a model, " \
                        "then `rubino chat` (or `rubino \"your prompt\"`)."

      # rubocop:disable Style/OptionalBooleanParameter -- overrides Thor's own
      # `def help(shell, subcommand = false)`; the positional boolean is Thor's
      # public signature (instance #help calls it positionally), not ours to change.
      def self.help(shell, subcommand = false)
        # Only decorate the TOP-LEVEL command listing (`rubino --help`), not a
        # per-command help page (`rubino help chat`) — those are dispatched with
        # the command name and handled by super unchanged.
        if subcommand
          super
          return
        end

        shell.say(TAGLINE)
        shell.say
        super
        shell.say(GETTING_STARTED)
        shell.say
      end
      # rubocop:enable Style/OptionalBooleanParameter

      # Allow passing prompt directly as default task:
      # rubino "my prompt"
      def self.default_command
        :chat
      end

      # Help flags recognized on any top-level command (#134).
      HELP_FLAGS = ["--help", "-h"].freeze

      # Intercept `--version`/`-v` at dispatch (#32). Thor otherwise routes a
      # bare `rubino --version` to the default `chat` task, which treats the
      # flag as a prompt and fails with an API-key error. Handle it here —
      # print the version and exit — before any chat/credential handling.
      #
      # Likewise intercept `rubino <command> --help` (#134): Thor 1.x only maps
      # a LEADING help flag to the help task, so `chat --help`/`prompt --help`
      # used to fall through as an unknown option, become the positional
      # prompt, and start a REAL agent run (provider call + memory writes).
      # Reroute to Thor's own `help <command>` before option parsing. Thor
      # subcommands (config/memory/sessions/jobs) already handle their own
      # `--help` and keep their richer subcommand listing.
      def self.start(given_args = ARGV, config = {})
        if ["--version", "-v"].include?(given_args.first)
          puts "rubino v#{Rubino::VERSION}"
          return
        end

        cmd = given_args.first.to_s.tr("-", "_")
        if given_args.drop(1).intersect?(HELP_FLAGS) && commands.key?(cmd) && !subcommands.include?(cmd)
          return super(["help", cmd], config)
        end

        # Reject an unknown LEADING flag before it is swallowed into the prompt
        # (F7). `chat` is the default command, so `rubino --frobnicate …` (or
        # `rubino prompt --frobnicate`) routes to chat/prompt and a TYPO'D flag
        # silently became part of the message text (or an empty-prompt run)
        # instead of erroring. Validate the leading `--flags` of a chat/prompt
        # invocation against that command's declared options here and surface a
        # clean "unknown flag" instead. A legitimate prompt that merely CONTAINS
        # `--` text (`rubino "run git log --oneline"`) is untouched: only a flag
        # in the LEADING run (before the first positional word) is checked.
        if (bad = unknown_leading_flag(given_args))
          report_early_error(given_args, "unknown flag '#{bad}'. Run `rubino #{chat_like_command(given_args)} --help` for valid flags")
        end

        # Force Thor's own `start` to RE-RAISE a Thor::Error (unknown command,
        # bad/malformed flag, ambiguous command, a subcommand's `raise
        # Thor::Error`) instead of swallowing it into a bare stderr line + exit
        # (its default). We catch it below so EVERY dispatch/argument error is
        # surfaced format-aware (#327): a clean stderr line under text, a
        # well-formed JSON error envelope on STDOUT under --output-format
        # json|stream-json — never an empty stdout, and never a raw backtrace.
        super(given_args, config.merge(debug: true))
      rescue Rubino::Database::BusyError => e
        # Final backstop (#333/#359): a SUSTAINED concurrent-migration lock that
        # outlived the connection retry budget must surface as a clean single
        # line + non-zero exit at this one chokepoint — never a raw Sequel/
        # SQLite backtrace from whichever command happened to touch the DB.
        # (Rubino::Database::BusyError is DEFINED in the always-loaded errors.rb
        # so naming it here can never NameError before the DB is autoloaded —
        # #445-regression fix.)
        warn "rubino: #{e.message}"
        exit(1)
      rescue Thor::Error, Rubino::ConfigurationError => e
        # A pre-run error that reached the boot chokepoint:
        #   * Thor::Error — a dispatch/argument failure (Thor::UndefinedCommandError
        #     carrying its own "Did you mean?" suggestion, MalformattedArgumentError
        #     for a bad `--max-turns abc`, a subcommand's `raise Thor::Error`).
        #   * Rubino::ConfigurationError — a source-raised config error, today a
        #     careless RUBINO_HOME pointing at a file / read-only parent (F13,
        #     raised by Rubino.ensure_directories!).
        # Surface it in the format the invocation asked for: under json/stream-json
        # emit the #327 envelope on stdout so automation can parse the failure (the
        # prior behaviour left stdout EMPTY for Thor errors, or leaked a raw Errno
        # backtrace for the home error); otherwise the clean one-line stderr Thor
        # itself would have printed. Never a raw backtrace; exit non-zero.
        report_early_error(given_args, e.message)
      end

      # The chat-like command an arg list dispatches to (`chat` or `prompt`), or
      # nil when it isn't one. A bare invocation (`rubino "hi"`, `rubino
      # --frobnicate`) falls to the default command (chat); an explicit
      # `rubino prompt …` / `rubino chat …` is named outright. Subcommands and
      # other top-level commands return nil — Thor already rejects unknown flags
      # for those, and only chat/prompt have a positional that swallows a typo.
      def self.chat_like_command(given_args)
        first = Array(given_args).first.to_s
        return first if %w[chat prompt].include?(first)
        # A leading flag / quoted prompt (not a known command) → default command.
        return "chat" if first.start_with?("-") || !commands.key?(first.tr("-", "_"))

        nil
      end

      # The first LEADING `--flag` of a chat/prompt invocation that isn't a
      # declared option, or nil (F7). "Leading" = appears before the first
      # POSITIONAL word, so a `--`-containing prompt is never misread: once a
      # non-flag token is seen, the rest is the prompt and is not inspected.
      # Value-taking flags consume their following token so `--model foo` doesn't
      # treat `foo` as a positional. Only inspects chat/prompt; other commands
      # return nil (Thor handles their flags).
      def self.unknown_leading_flag(given_args)
        command = chat_like_command(given_args)
        return nil unless command

        args = Array(given_args).map(&:to_s)
        # Drop the explicit command word when present; for the default-command
        # path the whole list is the chat args.
        args = args.drop(1) if %w[chat prompt].include?(args.first)
        known = known_flag_tokens(command)

        i = 0
        while i < args.size
          tok = args[i]
          break unless tok.start_with?("-") && tok != "-" # first positional ⇒ stop

          flag = tok.split("=", 2).first
          return flag unless known.include?(flag)

          # A known value-flag with a space-separated value consumes the next
          # token so it isn't mistaken for the first positional.
          i += value_flag?(command, flag) && !tok.include?("=") ? 2 : 1
        end
        nil
      end

      # The set of accepted flag spellings for a command — every declared
      # `--long`, `--no-long` (booleans), and short `-x` alias — so a typo is
      # caught but a real flag in any spelling is accepted.
      def self.known_flag_tokens(command)
        opts = commands[command]&.options || {}
        # --help/-h and the global --version/-v are always valid spellings; the
        # latter is handled at the top of #start when LEADING, but a non-leading
        # `chat --version` must still fall through to Thor (not be rejected as
        # "unknown"), preserving the pre-F7 dispatch behaviour.
        tokens = HELP_FLAGS + %w[--version -v]
        opts.each_value do |o|
          tokens << "--#{o.name.tr("_", "-")}"
          tokens << "--no-#{o.name.tr("_", "-")}" if o.type == :boolean
          Array(o.aliases).each { |a| tokens << a }
        end
        tokens.uniq
      end

      # True when a flag carries a value (so its next token is the value, not a
      # positional). Booleans don't; everything else does.
      def self.value_flag?(command, flag)
        opts = commands[command]&.options || {}
        opt = opts.values.find do |o|
          long = "--#{o.name.tr("_", "-")}"
          long == flag || Array(o.aliases).include?(flag)
        end
        opt && opt.type != :boolean
      end

      # Surfaces a pre-run error (a Thor dispatch/argument error caught in #start,
      # or any other boot-time failure that escapes a command body) in the
      # invocation's chosen output format, then exits non-zero (#327). Under
      # --output-format json|stream-json the message becomes the same
      # {type:"result", is_error:true, …} envelope ChatCommand#fail_arg! emits for
      # an empty prompt / invalid --output-format, so a json consumer ALWAYS gets
      # a parseable object on stdout; under text it is the clean `rubino: <msg>`
      # stderr line. The JSON path is wholly best-effort: an envelope hiccup must
      # never mask the underlying failure, so it falls back to the stderr line.
      def self.report_early_error(given_args, message, exit_code: 1)
        if json_output_requested?(given_args)
          begin
            $stdout.puts JSON.generate(Output::ResultSerializer.arg_error(message: message))
            $stdout.flush
          rescue StandardError
            warn "rubino: #{message}"
          end
        else
          warn "rubino: #{message}"
        end
        exit(exit_code)
      end

      # True when the raw CLI args ask for a machine-readable one-shot mode —
      # `--json`, or `--output-format json|stream-json` (hyphen or underscore,
      # `=`-joined or space-separated). Decided from the raw argv (NOT Thor's
      # parsed options) because the error we're reporting can be the very failure
      # that aborted option parsing, so parsed options may be unavailable. Mirrors
      # ChatCommand#json_requested? so the early-error envelope matches the
      # in-command one.
      def self.json_output_requested?(given_args)
        args = Array(given_args).map(&:to_s)
        return true if args.include?("--json")

        args.each_with_index do |a, i|
          if ["--output-format", "--output_format"].include?(a)
            val = args[i + 1].to_s.tr("-", "_")
            return true if %w[json stream_json].include?(val)
          elsif (m = a.match(/\A--output[-_]format=(.+)\z/))
            return true if %w[json stream_json].include?(m[1].tr("-", "_"))
          end
        end
        false
      end

      # Wrap subcommand help so `chat --help` / `prompt --help` stay within 80
      # columns (#217). Thor's stock #print_options lays the flags and their
      # descriptions out in a 2-column table padded to the WIDEST flag — and the
      # boolean variants (`[--no-x], [--skip-x]`) push that column past 60, so
      # every description row overflowed 80 (the longest hit 137) with no
      # wrapping. Render each option as its flag line followed by the
      # description wrapped + indented on its own line(s) instead: bounded by
      # construction, and it reads cleaner than the ragged padded table.
      HELP_WRAP_COLUMNS = 80
      HELP_DESC_INDENT  = 6

      def self.print_options(shell, options, group_name = nil)
        return if options.empty?

        shell.say(group_name ? "#{group_name} options:" : "Options:")
        options.reject(&:hide).each do |option|
          shell.say("  #{option.usage(0)}")
          next unless option.description

          wrap_help_description(option.description).each { |line| shell.say(line) }
        end
        shell.say ""
      end

      # Greedy word-wrap of a flag description to HELP_WRAP_COLUMNS, each line
      # indented HELP_DESC_INDENT. Wrapped here (not via Thor's print_wrapped)
      # so the bound is the fixed 80 the spec checks, not the live terminal
      # width. A single word longer than the budget is emitted on its own line
      # rather than dropped.
      def self.wrap_help_description(description)
        indent = " " * HELP_DESC_INDENT
        budget = HELP_WRAP_COLUMNS - HELP_DESC_INDENT
        lines  = []
        line   = +""
        description.to_s.split(/\s+/).each do |word|
          if line.empty?
            line << word
          elsif line.length + 1 + word.length <= budget
            line << " " << word
          else
            lines << (indent + line)
            line = +word
          end
        end
        lines << (indent + line) unless line.empty?
        lines
      end

      desc "setup", "Initialize rubino configuration and database"
      def setup
        SetupCommand.new.execute
      end

      # ----------------------------------------------------------------
      # chat — interactive and non-interactive
      # ----------------------------------------------------------------
      desc "chat [PROMPT]", "Chat with the agent (one-shot with -q)"

      # One-shot / non-interactive
      option :query,    aliases: "-q", type: :string, desc: "One-shot prompt (non-interactive)"

      # Attach image(s) to the turn's native vision slot. Repeatable:
      #   --image a.png --image b.jpg.
      # A single-value, repeatable string (not a greedy array) so a trailing
      # positional prompt — `--image pic.png "what is this?"` — stays the prompt
      # instead of being swallowed as a second image. Works in both one-shot
      # (-q) and interactive mode; @image tokens in the prompt itself are also
      # honoured. Aligns with `llm`'s -a/--attachment.
      option :image,    aliases: "-i", type: :string, repeatable: true,
                        desc: "Attach image file to the prompt (repeatable)"

      # Session management
      option :session,  aliases: "-s", type: :string,  desc: "Resume session by ID"
      option :resume,   aliases: "-r", type: :string,  desc: "Resume session by ID or title"
      option :continue, aliases: "-c", type: :boolean, desc: "Resume most recent session"
      option :new,                     type: :boolean,
                                       desc: "Start a fresh session (bare `chat` resumes the last one by default)"

      # Model / provider
      option :model, aliases: "-m", type: :string, desc: "Override model (e.g. claude-sonnet-4-5)"
      option :provider,                type: :string,  desc: "Override provider (e.g. bedrock, anthropic)"

      # Behavior
      option :yolo,                    type: :boolean, desc: "Skip all approval prompts"
      option :max_turns,               type: :numeric, desc: "Max tool iterations per turn"
      option :ignore_rules,            type: :boolean, desc: "Skip AGENTS.md and context files"

      # Machine-readable headless output (one-shot / -q only). `text` (default)
      # prints prose; `json` emits a single result object on stdout at
      # completion; `stream-json` emits JSONL (system→assistant→user→result).
      # In json/stream-json modes ALL JSON goes to stdout and ALL logs/errors to
      # stderr, and markdown rendering is suppressed. `--json` is an alias for
      # `--output-format json`.
      option :output_format, type: :string, banner: "FORMAT",
                             desc: "One-shot output: text | json | stream-json (default text)"
      option :json,          type: :boolean, desc: "Alias for --output-format json"

      # One-shot TEXT trace control. By default a `rubino prompt`/-q text run
      # prints a concise per-tool activity trace to STDERR (`· edit foo.rb`),
      # answer-only on STDOUT. --quiet/-Q silences that trace (machine path);
      # --verbose/-v widens each line's args. NOTE: -q is --query (the prompt
      # content), so the QUIET flag is the CAPITAL -Q (mirrors Hermes -q/-Q).
      option :quiet,         aliases: "-Q", type: :boolean,
                             desc: "Silence the one-shot stderr tool-activity trace (answer-only)"
      option :verbose,       aliases: "-v", type: :boolean,
                             desc: "Expand the one-shot stderr tool-activity trace (fuller args)"

      # Add extra allowed workspace roots at launch (repeatable), like Claude
      # Code's --add-dir. Write/edit tools then accept files under any added
      # root; an added dir's project context/skills are gated by folder-trust.
      option :add_dir,                 type: :string, repeatable: true,
                                       desc: "Add an extra allowed workspace directory (repeatable)"

      def chat(prompt = nil)
        # Support: rubino chat "prompt" as shorthand for -q
        opts = options.to_h.merge(prompt ? { query: prompt } : {})
        ChatCommand.new(opts).execute
      end

      # ----------------------------------------------------------------
      # Shorthand: rubino prompt "my question"
      # ----------------------------------------------------------------
      desc "prompt PROMPT", "Run a one-shot prompt (alias for chat -q)"
      option :model,        aliases: "-m", type: :string,  desc: "Override model"
      option :provider,                    type: :string,  desc: "Override provider"
      option :image,        aliases: "-i", type: :string, repeatable: true, desc: "Attach image file (repeatable)"
      option :session,      aliases: "-s", type: :string,  desc: "Session ID to resume"
      option :continue,     aliases: "-c", type: :boolean, desc: "Resume most recent session"
      option :resume,       aliases: "-r", type: :string,  desc: "Resume by ID or title"
      option :yolo,                        type: :boolean, desc: "Skip approval prompts"
      option :max_turns,                   type: :numeric, desc: "Max tool iterations"
      option :ignore_rules,                type: :boolean, desc: "Skip AGENTS.md/context files"
      option :add_dir,                     type: :string, repeatable: true,
                                           desc: "Add an extra allowed workspace directory (repeatable)"
      option :output_format,               type: :string, banner: "FORMAT",
                                           desc: "Output: text | json | stream-json (default text)"
      option :json,                        type: :boolean, desc: "Alias for --output-format json"
      option :quiet,        aliases: "-Q", type: :boolean,
                            desc: "Silence the stderr tool-activity trace (answer-only)"
      option :verbose,      aliases: "-v", type: :boolean,
                            desc: "Expand the stderr tool-activity trace (fuller args)"
      def prompt(*args)
        query = args.join(" ")
        opts = options.to_h.merge(query: query)
        ChatCommand.new(opts).execute
      end

      desc "config SUBCOMMAND", "Manage configuration"
      subcommand "config", ConfigCommand

      desc "memory SUBCOMMAND", "Manage persistent memories"
      subcommand "memory", MemoryCommand

      desc "sessions SUBCOMMAND", "Manage chat sessions"
      subcommand "sessions", SessionCommand

      desc "jobs SUBCOMMAND", "Manage background jobs"
      subcommand "jobs", JobsCommand

      desc "skills SUBCOMMAND", "Manage skills (list, enable, install, update)"
      subcommand "skills", SkillsCommand

      desc "tools", "List available tools"
      def tools
        ToolsCommand.new.execute
      end

      desc "server", "Start the JSON API server"
      option :port, type: :numeric, default: 4820, desc: "Port to listen on"
      option :host, type: :string, desc: "Host/interface to bind (default 127.0.0.1; pass 0.0.0.0 to expose)"
      option :api_key, type: :string, desc: "Bearer token required on every request"
      def server
        ServerCommand.new(options).execute
      end

      # The usage label matches the registered command name (tls_cert) so
      # `--help` and `tree` render the SAME name (#20); Thor still dispatches
      # the hyphenated spelling (`rubino tls-cert`) via its name normalization.
      desc "tls_cert", "Print the self-signed TLS certificate PEM"
      def tls_cert
        $stdout.write(API::TLS.ensure_cert!)
      end

      desc "doctor", "Check system health"
      def doctor
        DoctorCommand.new.execute
      end

      desc "version", "Show version"
      def version
        Rubino.ui.info("rubino v#{Rubino::VERSION}")
      end

      desc "update", "Update rubino to the latest published version"
      def update
        ui = Rubino.ui
        current = Rubino::VERSION

        case Rubino::UpdateCheck.install_method
        when :gem
          ok = system(*Rubino::UpdateCheck.gem_update_command)
          unless ok
            ui.warning("gem update failed. If this is a permission error, re-run the installer or try `gem update --user-install #{Rubino::UpdateCheck::GEM_NAME}`.")
            return
          end
          new_v = Rubino::UpdateCheck.installed_gem_version(Rubino::UpdateCheck::GEM_NAME)
          if new_v && Gem::Version.new(new_v) > Gem::Version.new(current)
            ui.info("rubino is now on v#{new_v} (was v#{current}).")
            ui.status("Restart any running rubino sessions to pick up the new version.")
          else
            ui.info("rubino is already up to date (v#{current}).")
          end
        else
          ui.warning("rubino wasn't installed from RubyGems (built from source / dev checkout).")
          ui.status("Re-run the installer to update:")
          ui.status("  curl -fsSL https://raw.githubusercontent.com/Jhonnyr97/rubino-agent/main/install.sh | bash")
        end
      ensure
        # Drop the cached notice so the boot footer doesn't linger after update.
        Rubino::UpdateCheck.clear_cache!
      end
    end
  end
end
