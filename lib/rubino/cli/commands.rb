# frozen_string_literal: true

require "thor"

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

      # Allow passing prompt directly as default task:
      # rubino "my prompt"
      def self.default_command
        :chat
      end

      desc "setup", "Initialize rubino configuration and database"
      def setup
        SetupCommand.new.execute
      end

      # ----------------------------------------------------------------
      # chat — interactive and non-interactive
      # ----------------------------------------------------------------
      desc "chat [PROMPT]", "Chat with the agent (interactive or one-shot with -q)"

      # One-shot / non-interactive
      option :query,    aliases: "-q", type: :string,  desc: "One-shot prompt (non-interactive)"

      # Attach image(s) to the turn's native vision slot. Repeatable:
      #   --image a.png --image b.jpg.
      # A single-value, repeatable string (not a greedy array) so a trailing
      # positional prompt — `--image pic.png "what is this?"` — stays the prompt
      # instead of being swallowed as a second image. Works in both one-shot
      # (-q) and interactive mode; @image tokens in the prompt itself are also
      # honoured. Aligns with `llm`'s -a/--attachment.
      option :image,    aliases: "-i", type: :string, repeatable: true, desc: "Attach image file to the prompt (repeatable)"

      # Session management
      option :session,  aliases: "-s", type: :string,  desc: "Resume session by ID"
      option :resume,   aliases: "-r", type: :string,  desc: "Resume session by ID or title"
      option :continue, aliases: "-c", type: :boolean, desc: "Resume most recent session"
      option :new,                     type: :boolean, desc: "Start a fresh session (bare `chat` resumes the last one by default)"

      # Model / provider
      option :model,    aliases: "-m", type: :string,  desc: "Override model (e.g. claude-sonnet-4-5)"
      option :provider,                type: :string,  desc: "Override provider (e.g. bedrock, anthropic)"

      # Behavior
      option :yolo,                    type: :boolean, desc: "Skip all approval prompts"
      option :max_turns,               type: :numeric, desc: "Max tool iterations per turn"
      option :ignore_rules,            type: :boolean, desc: "Skip AGENTS.md and context files"

      # Add extra allowed workspace roots at launch (repeatable), like Claude
      # Code's --add-dir. Write/edit tools then accept files under any added
      # root; an added dir's project context/skills are gated by folder-trust.
      option :add_dir,                 type: :string, repeatable: true, desc: "Add an extra allowed workspace directory (repeatable)"

      def chat(prompt = nil)
        # Support: rubino chat "prompt" as shorthand for -q
        opts = options.to_h.merge(prompt ? { query: prompt } : {})
        ChatCommand.new(opts).execute
      end

      # ----------------------------------------------------------------
      # Shorthand: rubino prompt "my question"
      # ----------------------------------------------------------------
      desc "prompt PROMPT", "Run a one-shot prompt (non-interactive, alias for chat -q)"
      option :model,        aliases: "-m", type: :string,  desc: "Override model"
      option :provider,                    type: :string,  desc: "Override provider"
      option :image,        aliases: "-i", type: :string, repeatable: true, desc: "Attach image file (repeatable)"
      option :session,      aliases: "-s", type: :string,  desc: "Session ID to resume"
      option :continue,     aliases: "-c", type: :boolean, desc: "Resume most recent session"
      option :resume,       aliases: "-r", type: :string,  desc: "Resume by ID or title"
      option :yolo,                        type: :boolean, desc: "Skip approval prompts"
      option :max_turns,                   type: :numeric, desc: "Max tool iterations"
      option :ignore_rules,                type: :boolean, desc: "Skip AGENTS.md/context files"
      option :add_dir,                     type: :string, repeatable: true, desc: "Add an extra allowed workspace directory (repeatable)"
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

      desc "tls-cert", "Print the agent's self-signed TLS certificate PEM (generating it if absent)"
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
