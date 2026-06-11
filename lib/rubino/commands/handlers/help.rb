# frozen_string_literal: true

module Rubino
  module Commands
    module Handlers
      # The `/help` and `/commands` listings (and the unknown-command
      # "Available:" roster), extracted from Commands::Executor (batch B). A plain
      # collaborator given the command `loader` and the `ui` — it owns the
      # built-in/keys/input reference text and the custom-command discovery copy.
      class Help
        def initialize(ui:, loader:)
          @ui = ui
          @loader = loader
        end

        # All known slash commands (built-ins + discovered custom), used for the
        # "Available:" hint on an unknown command (L6 — previously listed only
        # custom commands, which is usually empty).
        def available_commands
          custom = begin
            @loader.names
          rescue StandardError
            []
          end
          (BuiltIns::NAMES + custom).uniq
        end

        def show_help
          @ui.info("Slash commands run actions or reusable prompts. Type /<name>; /help is this list.")
          @ui.blank_line
          @ui.info("Built-in:")
          rows  = help_builtin_rows
          width = rows.map { |name, _| name.length }.max
          rows.each do |name, desc|
            @ui.info("  #{name.ljust(width)}  - #{desc}")
          end
          @ui.blank_line

          # The `@` file-picker is a discoverable composer feature (type `@` to
          # autocomplete a workspace file) but was undocumented in /help (F14).
          # /paste and /clear-images already appear once under "Built-in" above,
          # so they're NOT repeated here — this section is image/file INPUT only,
          # no command rows (#87 de-dup).
          @ui.info("Input:")
          @ui.info("  ! <command>   - run a shell command yourself, no approval; output joins the context")
          @ui.info("  @<path>       - autocomplete a workspace file into the prompt")
          @ui.info("  @<image>      - attach an image (png/jpg/jpeg/gif/webp/bmp) to the turn")
          @ui.info("  <image path>  - drop or paste an image file path to attach it")
          @ui.blank_line

          # The keystroke vocabulary was invisible in /help (#87): a newcomer
          # couldn't learn how to cancel a turn, drive the approval menu, or that
          # Tab completes. One compact reference line covers it.
          @ui.info("Keys:")
          @ui.info("  ↑/↓ + Enter   - choose in the approval menu")
          @ui.info("  Enter         - send; during a turn, interrupt it and run this next")
          @ui.info("  Alt-Enter     - queue this to run after the current turn (or /queued <msg>)")
          @ui.info("  Shift-Tab     - cycle mode (default → plan → yolo)")
          @ui.info("  Ctrl-O        - reveal the last reasoning (collapsed or hidden)")
          @ui.info("  Ctrl-C        - cancel the turn (twice to exit)")
          @ui.info("  Esc Esc       - rewind to an earlier message (fork + edit & resend)")
          @ui.info("  Tab           - complete the highlighted /command or @file")
          @ui.info("  /             - start a command;  @  attach a file/image")
          @ui.blank_line

          custom = @loader.all
          if custom.any?
            @ui.info("Custom commands  (run with /<name>; add --preview to see the prompt first):")
            custom.each do |cmd|
              @ui.info("  /#{cmd.name}#{custom_desc(cmd)}")
            end
          else
            @ui.info("Custom commands  (none yet — run /commands to learn how to add one)")
          end
        end

        def show_commands
          commands = @loader.all
          return explain_empty_commands if commands.empty?

          @ui.info("Custom commands  (run with /<name>; add --preview to see the prompt first):")
          commands.each do |cmd|
            @ui.info("  /#{cmd.name}#{custom_desc(cmd)}")
          end
        end

        private

        # The Built-in rows for /help, with synonyms collapsed so /help never
        # shows two rows that say the same thing (#87): /exit and /quit share one
        # "End session" row as "/exit, /quit". Everything else passes through in
        # the BuiltIns order.
        def help_builtin_rows
          rows = []
          seen = {}
          BuiltIns::DESCRIPTIONS.each do |name, desc|
            if (canonical = seen[desc])
              rows[canonical[:index]][0] = "#{canonical[:name]}, #{name}"
            else
              seen[desc] = { index: rows.length, name: name }
              rows << [name, desc]
            end
          end
          rows
        end

        # The cryptic old empty-state ("Add .md files to .rubino/commands/")
        # named a dir without ever explaining what a command IS. Now we explain
        # the concept, name the REAL configured paths, and show a concrete example.
        def explain_empty_commands
          @ui.info("Custom commands are reusable prompts you trigger with a slash. Each is a")
          @ui.info("Markdown file in a commands directory; the file body becomes the prompt")
          @ui.info("($ARGUMENTS / $1..$9 expand to what you type after the command).")
          @ui.blank_line
          @ui.info("No custom commands found yet.")
          @ui.blank_line
          @ui.info("Searched: #{command_dirs.join(", ")}")
          @ui.info("Create one, e.g. .rubino/commands/review.md:")
          @ui.blank_line
          @ui.info("    ---")
          @ui.info("    description: Review the current diff for bugs")
          @ui.info("    ---")
          @ui.info("    Review the staged diff. Flag correctness bugs only. $ARGUMENTS")
          @ui.blank_line
          @ui.info("Then run:  /review focus on the auth change")
        end

        # The directories the loader actually searches, for the empty-state copy.
        # Resolves through Loader.resolve_path so the "Searched:" line reports the
        # real paths (RUBINO_HOME-aware), not a literal ~/.rubino never searched.
        def command_dirs
          paths = Rubino.configuration.dig("commands", "paths")
          paths = Rubino::Config::Defaults.to_hash.dig("commands", "paths") if paths.nil?
          Array(paths).map { |dir| Loader.resolve_path(dir) }
        rescue StandardError
          Loader.default_command_paths
        end

        # "  - <description>" suffix for a custom-command listing, omitted when the
        # command carries no description so the line stays clean.
        def custom_desc(cmd)
          desc = cmd.description.to_s.strip
          desc.empty? ? "" : "  - #{desc}"
        end
      end
    end
  end
end
