# frozen_string_literal: true

require "thor"

module Rubino
  module CLI
    # Subcommands for managing chat sessions
    class SessionCommand < Thor
      # Clean `tree`/help label instead of the underscored class-name default (F12).
      namespace "rubino sessions"

      def self.exit_on_failure?
        true
      end

      # Bare `rubino sessions` LISTS rather than printing the subcommand help
      # (item 3): listing is the overwhelmingly common intent, and the help was
      # a dead end that hid the very thing the user came for. The subcommands
      # (show/delete/compact) and `sessions help` are still available; Thor maps
      # a leading `--help`/`-h` to its own help task before this default fires.
      def self.default_command
        :list
      end

      # Drop Thor's inherited `tree` so its banner doesn't render the doubled
      # "rubino rubino sessions tree" (#327); the top-level `rubino tree` covers it.
      remove_command :tree

      desc "list", "List recent sessions in this directory (--all for every dir)"
      option :limit,  type: :numeric, default: 20, desc: "Max results"
      option :status, type: :string,  desc: "Filter by status"
      option :search, type: :string,  desc: "Filter by title (substring match)"
      option :all,    type: :boolean, default: false,
                      desc: "List sessions from every directory, not just this one"
      def list
        guard_corrupt_database!
        Rubino.ensure_database_ready!
        repo = Session::Repository.new
        # Reap sessions left "active" by a process that died without ending them
        # (hard terminal kill / SIGKILL, #11) so the list never shows a stale
        # "active" for a window that is actually gone.
        repo.reap_orphaned_active!
        # Default to THIS directory's sessions (#334) so a multi-folder user
        # isn't shown another project's history; --all opts back into the global
        # listing. nil cwd ⇒ unscoped (all dirs).
        cwd = options[:all] ? nil : Rubino::Workspace.primary_root
        sessions = repo.list(limit: options[:limit], status: options[:status],
                             search: options[:search], cwd: cwd)

        if sessions.empty?
          msg = options[:all] ? "No sessions found." : "No sessions found in this directory (try --all)."
          Rubino.ui.info(msg)
          return
        end

        rows = sessions.map do |s|
          # cwd (the launch dir) lets a multi-folder/multi-tab user tell which
          # project each session belongs to (r5 MF-4); home-collapsed and
          # terminal-escape-sanitized like the other stored fields.
          [self.class.safe(s[:id][0..7]),
           self.class.safe(s[:title] || "(untitled)"),
           self.class.safe(self.class.collapse_home(s[:cwd])),
           self.class.safe(s[:status]),
           self.class.safe(s[:message_count].to_s),
           self.class.safe(s[:updated_at] || s[:created_at])]
        end

        Rubino.ui.table(
          headers: %w[ID Title Dir Status Messages Updated],
          rows: rows
        )
      end

      desc "show ID", "Show session details"
      def show(id)
        guard_corrupt_database!
        Rubino.ensure_database_ready!
        repo = Session::Repository.new
        session = repo.find(id)

        # One error, one style (#20): Thor already prints the Thor::Error message
        # to stderr and exits non-zero (exit_on_failure?), so the extra styled
        # ui.error line was the same failure repeated in a second format.
        raise Thor::Error, "session not found: #{id}" if session.nil?

        self.class.render(session, ui: Rubino.ui)
      end

      # ONE session-details rendering for both surfaces (#183): the CLI verb
      # above and the in-chat `/sessions show <id>` (Commands::Executor).
      def self.render(session, ui:)
        # Title/Model are attacker-influenceable (the title is generated from
        # the conversation), and the rest are defensively sanitized too: `info`
        # does NOT neutralize escapes, so a raw `\e]0;…\a` / `\e[2J` here would
        # hijack the window title or clear the screen (CWE-150, R4-N2). Render
        # any control bytes as visible caret notation instead.
        ui.info("Session: #{safe(session[:id])}")
        ui.info("Title: #{safe(session[:title] || "(untitled)")}")
        ui.info("Status: #{safe(session[:status])}")
        ui.info("Dir: #{safe(collapse_home(session[:cwd]))}")
        ui.info("Model: #{safe(session[:model])}")
        ui.info("Messages: #{safe(message_summary(session[:id]))}")
        ui.info("Tokens: #{safe(token_total(session[:id]))}")
        ui.info("Created: #{safe(session[:created_at])}")
        ui.info("Updated: #{safe(session[:updated_at])}")

        return unless session[:parent_session_id]

        ui.info("Parent: #{safe(session[:parent_session_id])}")
      end

      # Truthful, CUMULATIVE message count for `sessions show` (#382). The cached
      # sessions.message_count column only counts top-level turns and hides every
      # assistant(tool_use)/tool(result) row, so it under-reports a tool-heavy
      # session. Count the actual messages table and label the tool rows so the
      # breakdown is honest (e.g. "12 (4 tool)"). Falls back to the cached column
      # if the live count can't be read — a display detail must not raise here.
      def self.message_summary(session_id)
        return nil unless session_id

        by_role = Session::Store.new.count_by_role(session_id)
        total   = by_role.values.sum
        tool    = by_role["tool"].to_i
        tool.positive? ? "#{total} (#{tool} tool)" : total.to_s
      rescue StandardError
        nil
      end

      # Truthful cumulative token total for `sessions show` (#382): the SUM over
      # all persisted messages, not the non-cumulative cached column.
      def self.token_total(session_id)
        return nil unless session_id

        Session::Store.new.token_sum(session_id)
      rescue StandardError
        nil
      end

      # Neutralize terminal-control bytes in untrusted stored session fields to
      # visible caret notation before the non-sanitizing `info` funnel (CWE-150).
      def self.safe(text)
        Util::Output.sanitize_terminal(text)
      end

      # Home-collapsed display path for a session's launch dir. Returns a dash
      # for sessions created before the cwd column existed (NULL cwd) so the
      # column stays aligned.
      def self.collapse_home(path)
        return "—" if path.nil? || path.to_s.empty?

        home = Dir.home
        str = path.to_s
        str.start_with?(home) ? str.sub(home, "~") : str
      rescue ArgumentError
        path.to_s
      end

      desc "delete ID", "Permanently delete a session and all its messages/events"
      option :force, type: :boolean, default: false, aliases: "-f",
                     desc: "Skip the confirmation prompt"
      def delete(id)
        guard_corrupt_database!
        Rubino.ensure_database_ready!
        repo = Session::Repository.new
        session = repo.find(id)

        # Single-styled not-found error (#20), as in #show above.
        raise Thor::Error, "session not found: #{id}" if session.nil?

        self.class.destroy_with_confirm(session, repo: repo, ui: Rubino.ui, force: options[:force])
      end

      # ONE confirm-and-destroy flow for both surfaces (#183): the CLI verb
      # above and the in-chat `/sessions delete <id>`.
      def self.destroy_with_confirm(session, repo:, ui:, force: false)
        unless force
          confirmed = ui.confirm_destructive(
            "Delete session #{session[:id][0..7]} '#{session[:title] || "(untitled)"}'? " \
            "This will also remove its messages, events, and tool calls."
          )
          unless confirmed
            ui.info("Aborted.")
            return
          end
        end

        repo.destroy!(session[:id])
        ui.success("Deleted session #{session[:id][0..7]}.")
      end

      desc "compact ID", "Manually trigger compaction on a session"
      def compact(id)
        guard_corrupt_database!
        Rubino.ensure_database_ready!
        repo = Session::Repository.new
        session = repo.find(id)

        # Single-styled not-found error (#20), as in #show above.
        raise Thor::Error, "session not found: #{id}" if session.nil?

        Rubino.ui.info("Compacting session #{session[:id][0..7]}...")
        # Measure BEFORE so the savings line reports the TRUTHFUL before→after
        # delta (item 4) — consistent with the interactive `/compact`, which
        # reports `~X → ~Y tokens (saved ~N; A → B messages)`. The compressor's
        # own `saved_tokens` is only the removed-middle estimate (it ignores the
        # inserted summary), so we compute the delta over the persisted rows.
        store  = Session::Store.new
        before = estimate_session_tokens(store, session[:id], model_id: session[:model])

        # Pass the RESOLVED full id, not the user's short id (#352): the
        # Compressor now re-resolves internally too, but feeding it the full id
        # keeps the contract explicit and the not-found path honest.
        compressor = Context::Compressor.new(session_id: session[:id])
        result = compressor.compact!

        # A no-op compaction must NOT print the "┄ compacted · saved 0 tok ┄"
        # fake success (#352): a session with nothing to compact (0 messages, or
        # too few to split) should say so plainly. Only a real compaction —
        # something was actually moved into a summary — renders the saved-tokens
        # line.
        if result[:skipped]
          threshold = result[:minimum_messages]
          bar = threshold ? " (needs >= #{threshold} messages)" : ""
          raise Thor::Error,
                "nothing to compact in session #{session[:id][0..7]}: " \
                "it has too few messages to summarize#{bar}."
        end

        after = estimate_session_tokens(store, result[:target_session_id], model_id: session[:model])
        delta = before - after
        Rubino.ui.compression_finished(result.merge(saved_tokens: delta))
        change = delta >= 0 ? "saved ~#{delta} tok" : "grew ~#{-delta} tok"
        msgs  = if result[:original_messages] && result[:compacted_messages]
                  "; #{result[:original_messages]} → #{result[:compacted_messages]} messages"
                else
                  ""
                end
        Rubino.ui.info("Context: ~#{before} → ~#{after} tokens (#{change}#{msgs}).")
      end

      private

      # The same chars/4 estimate the compaction thresholds and the interactive
      # `/compact` (Commands::Executor) run on, over a session's stored messages
      # — so the CLI `sessions compact` reports the SAME truthful before→after
      # delta (item 4). Private so Thor never exposes it as a `sessions` verb.
      def estimate_session_tokens(store, session_id, model_id:)
        budget = Context::TokenBudget.new(model_id: model_id, config: Rubino.configuration)
        budget.estimate_tokens(store.for_session(session_id).map { |m| { content: m.content } })
      end

      # Turn a PRESENT-but-UNUSABLE on-disk DB (corrupt image, or the duplicate
      # `schema_info` rows a concurrent first-boot race leaves, #race) into a
      # clean, actionable diagnostic instead of leaking a raw Sequel/sqlite3
      # backtrace (HIGH-2 / #333 / #359). Without this the first DB touch
      # (Repository.new → query) throws and dumps ~20 lines of trace. Thor prints
      # a Thor::Error's message to stderr and exits non-zero with no backtrace.
      def guard_corrupt_database!
        message = Rubino.database_repair_message
        raise Thor::Error, message if message
      end
    end
  end
end
