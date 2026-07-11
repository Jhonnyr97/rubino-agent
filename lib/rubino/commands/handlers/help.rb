# frozen_string_literal: true

module Rubino
  module Commands
    module Handlers
      # The `/help` and `/commands` listings (and the unknown-command
      # "Available:" roster), extracted from Commands::Executor (batch B). A plain
      # collaborator given the command `loader` and the `ui` — it owns the
      # built-in/keys/input reference text and the custom-command discovery copy.
      class Help
        include Display

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

        # Closest known slash command to a mistyped +name+ (no leading slash),
        # rendered WITH its slash for the "Did you mean /X?" hint, or nil when
        # none is close enough (FRICTION-4). Uses Ruby's stdlib SpellChecker
        # (DidYouMean) — the same Levenshtein matcher Thor/Bundler use — so the
        # distance threshold scales with command length. Best-effort: any
        # matcher hiccup just yields no suggestion.
        def closest_command(name)
          require "did_you_mean"
          bare  = name.to_s.delete_prefix("/")
          names = available_commands.map { |c| c.to_s.delete_prefix("/") }
          match = DidYouMean::SpellChecker.new(dictionary: names).correct(bare).first
          match && "/#{match}"
        rescue StandardError
          nil
        end

        # The unknown-command tail (FRICTION-4): a "Did you mean /X?" line for the
        # closest match (when one is close enough) followed by the full Available
        # roster. Lives here next to the command list it reads.
        def suggest_and_list(name)
          suggestion = closest_command(name)
          @ui.info("Did you mean #{suggestion}?") if suggestion
          @ui.info("Available: #{available_commands.join(", ")}")
          :handled
        end

        def show_help
          @ui.info("Slash commands run actions or reusable prompts. Type /<name>; /help is this list.")
          @ui.blank_line
          @ui.info("Built-in:")
          rows  = help_builtin_rows
          width = rows.map { |name, _| name.length }.max
          rows.each do |name, desc|
            help_line("  #{name.ljust(width)}  - #{desc}")
          end
          @ui.blank_line

          # The `@` file-picker is a discoverable composer feature (type `@` to
          # autocomplete a workspace file) but was undocumented in /help (F14).
          # /paste and /clear-images already appear once under "Built-in" above,
          # so they're NOT repeated here — this section is image/file INPUT only,
          # no command rows (#87 de-dup).
          @ui.info("Input:")
          help_line("  ! <command>   - run a shell command yourself, no approval; output joins the context")
          help_line("  @<path>       - autocomplete a workspace file into the prompt")
          help_line("  @<image>      - attach an image (png/jpg/jpeg/gif/webp/bmp) to the turn")
          help_line("  <image path>  - drop or paste an image file path to attach it")
          @ui.blank_line

          # The keystroke vocabulary was invisible in /help (#87): a newcomer
          # couldn't learn how to cancel a turn, drive the approval menu, or that
          # Tab completes. One compact reference line covers it.
          @ui.info("Keys:")
          help_line("  ↑/↓ + Enter   - choose in the approval menu")
          help_line("  Enter         - send; during a turn, interrupt it and run this next")
          help_line("  Alt-Enter     - queue this to run after the current turn (or /queued <msg>)")
          help_line("  Shift-Tab     - cycle mode (default → plan → yolo)")
          help_line("  Tab           - complete the highlighted /command or @file (empty input: cycle agent)")
          help_line("  Ctrl-O        - reveal the last reasoning (collapsed or hidden)")
          help_line("  Ctrl-C        - cancel the turn (twice to exit)")
          help_line("  Esc Esc       - rewind to an earlier message (fork + edit & resend)")
          help_line("  /             - start a command;  @  attach a file/image")
          @ui.blank_line

          show_agents_help
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

        # The available primary agents (switch with /agent <name>, a bare
        # /<name>, or Tab) and one-shot subagents (/<name> <message>) — #320.
        # Best-effort: the registry is stable within a process, but a hiccup
        # must never break /help.
        def show_agents_help
          registry = Rubino.agent_registry
          current  = Rubino::ActiveAgent.current
          @ui.info("Agents  (switch with /agent <name>, a bare /<name>, or Tab; current marked ▸):")
          registry.primary_agents.each do |a|
            marker = a.name == current ? "▸" : " "
            help_line("  #{marker} /#{a.name.ljust(8)} - #{a.description}")
          end
          registry.subagents.each do |a|
            help_line("    /#{a.name.ljust(8)} - #{a.description} (one-shot: /#{a.name} <message>)")
          end
        rescue StandardError
          nil
        end

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
          # Include Claude Code compat paths so the "Searched:" line is honest.
          all_paths = Loader::CLAUDE_PATHS + Array(paths)
          all_paths.map { |dir| Loader.resolve_path(dir) }
        rescue StandardError
          Loader.default_command_paths
        end

        # "  [arg-hint]  - <description>" suffix for a custom-command listing.
        # The argument hint is shown when present (Claude Code /command compat);
        # the description follows after " - "; omitted when both are empty.
        def custom_desc(cmd)
          hint = cmd.respond_to?(:argument_hint) ? cmd.argument_hint.to_s.strip : ""
          desc = cmd.description.to_s.strip
          parts = []
          parts << "[#{hint}]" unless hint.empty?
          parts << "- #{desc}" unless desc.empty?
          parts.empty? ? "" : "  #{parts.join("  ")}"
        end

        # Emits one help row, wrapping the DESCRIPTION at the terminal width so
        # the longest rows (~88ch — the `! <command>` / Alt-Enter lines) no
        # longer get hard-cut at a standard 80-col terminal (F-help-wrap). The
        # row is split at the FIRST " - " separator: the label column (left of
        # it, plus the "- " gutter) is preserved on the first line, and every
        # continuation line HANG-INDENTS under the description so the wrapped
        # text reads as one aligned column rather than spilling to column 0.
        # A row with no " - " (free-form copy) is emitted verbatim.
        def help_line(row)
          label, desc = row.split(" - ", 2)
          return @ui.info(row) if desc.nil?

          indent = " " * "#{label} - ".length
          width  = terminal_width
          wrap_help_desc(desc, width - indent.length).each_with_index do |seg, i|
            @ui.info(i.zero? ? "#{label} - #{seg}" : "#{indent}#{seg}")
          end
        end

        # Word-wraps a description into lines no wider than +width+ columns,
        # breaking on spaces; an over-long single word (a long path/flag) is
        # left intact rather than split mid-token. Width is floored so a very
        # narrow terminal still makes progress instead of looping.
        def wrap_help_desc(desc, width)
          width = [width, 8].max
          words = desc.split
          lines = []
          line  = +""
          words.each do |word|
            if line.empty?
              line << word
            elsif line.length + 1 + word.length <= width
              line << " " << word
            else
              lines << line
              line = +word
            end
          end
          lines << line unless line.empty?
          lines.empty? ? [""] : lines
        end
      end
    end
  end
end
