# frozen_string_literal: true

require "shellwords"

module Rubino
  # Wires the `formatters:` config block to something real. Before this,
  # `formatters: {}` was a pure stub: declared in Config::Defaults, read by
  # NOTHING. This module is what Tools::WriteTool / Tools::EditTool call after
  # a SUCCESSFUL write/edit to run the user's configured command.
  #
  #   formatters:
  #     "*.rb": "rubocop -A --fail-level=fatal"
  #     "*.js": "prettier --write"
  #
  # Design (see docs/configuration.md#formatters):
  #
  # * Matching: each key is a glob matched against the touched file's
  #   BASENAME (Security::PatternMatcher — the same glob engine `permissions:`
  #   uses), not the full path — so "*.rb" means "any .rb file", unambiguous
  #   regardless of which directory it lives under. The FIRST matching key in
  #   `formatters:` declaration order wins (only one formatter runs per file).
  #
  # * Argument contract: the touched file's absolute path is appended as the
  #   command's LAST shell argument (shell-escaped) — exactly how you'd type
  #   `rubocop -A --fail-level=fatal path/to/file.rb` by hand. There is no
  #   `{file}`-style placeholder: every example in the docs (rubocop/
  #   prettier/black) already expects the path as a trailing positional
  #   argument, so the simplest thing that could work is also the thing that
  #   matches real CLI usage.
  #
  # * Trust: the command string comes from the user's OWN config.yml — same
  #   trust tier as `permissions:` patterns and `mcp.servers` commands, so no
  #   approval prompt gates it. It is still spawned through the SAME OS
  #   write-jail every other shell spawn goes through
  #   (Tools::ShellTool.sandboxed_bash_argv -> Security::Sandbox): a
  #   formatter is a trusted COMMAND, not a license to bypass the sandbox.
  #
  # * Execution: SYNCHRONOUS, bounded by TIMEOUT_SECONDS. Formatters are
  #   fast, deterministic, local commands (unlike rubino's backgrounded
  #   skill-distillation / memory-extraction review forks, which are slow
  #   LLM-backed side work) — the model/user want the on-disk content to
  #   already reflect the formatted result the instant the tool call returns.
  #
  # * Failure handling: a non-zero exit / timeout / spawn error is
  #   best-effort — it NEVER raises and NEVER fails the write/edit call (the
  #   file itself was already written successfully); it only comes back as a
  #   one-line note for the caller to append to the tool's output, plus a
  #   structured log line (mirrors BackgroundReviewJob's
  #   `jobs.background_review.error` — log, don't raise, don't confabulate a
  #   failure into a hard tool error).
  module Formatters
    # Wall-clock budget for a single formatter run. Generous for `rubocop -A`
    # on a large file, but still bounded so a hung/misconfigured command can't
    # wedge the write/edit call forever.
    TIMEOUT_SECONDS = 30

    # Cap on the formatter's own captured stdout+stderr kept for the note —
    # just enough to tell the model/user WHY it failed, never the full dump.
    MAX_NOTE_OUTPUT_BYTES = 4_000
    MAX_NOTE_OUTPUT_LINES = 20

    module_function

    # Runs the configured formatter for +expanded_path+ (an absolute,
    # already-written path) when a `formatters:` glob matches its basename.
    #
    # Returns nil when formatters are unconfigured or nothing matches — the
    # untouched, pre-existing no-op behavior — otherwise a Hash:
    #   { changed: bool, command: String, note: String or nil }
    # `note` is nil on a quiet success (the formatter ran but left the file
    # byte-identical — nothing worth telling the model), and set on either a
    # real change or a failure.
    #
    # NEVER raises: every failure path (bad config, spawn error, timeout,
    # non-zero exit) degrades to a note/log, never an exception, so a
    # formatter can never turn a successful write/edit into a tool error.
    def run(expanded_path, display_path: expanded_path)
      command = command_for(expanded_path)
      return nil unless command

      before  = safe_read(expanded_path)
      outcome = spawn_formatter(command, expanded_path)
      after   = safe_read(expanded_path)
      changed = !before.nil? && before != after

      { changed: changed, command: command,
        note: note_for(command: command, display_path: display_path, outcome: outcome, changed: changed) }
    rescue StandardError => e
      Rubino.logger&.warn(event: "formatters.run_failed", command: command,
                          error: e.message, error_class: e.class.name)
      nil
    end

    # The command for the FIRST `formatters:` key (declaration order) whose
    # glob matches the file's basename, or nil when formatters are
    # unconfigured / nothing matches. A blank command value is skipped (a
    # config typo shouldn't silently no-op the whole rule for every OTHER
    # file too, but nor should it try to shell out to "").
    def command_for(expanded_path)
      table = Rubino.configuration&.dig("formatters")
      return nil unless table.is_a?(Hash) && !table.empty?

      basename = File.basename(expanded_path.to_s)
      _pattern, command = table.find do |pattern, cmd|
        cmd.to_s.strip != "" && pattern_matcher.matches_pattern?(basename, pattern.to_s)
      end
      command
    end

    def pattern_matcher
      @pattern_matcher ||= Security::PatternMatcher.new
    end

    def safe_read(path)
      File.binread(path)
    rescue StandardError
      nil
    end

    # Spawns `<command> <shell-escaped path>` through the SAME OS write-jail
    # every other shell spawn goes through — the single source of truth
    # ShellTool itself uses (Tools::ShellTool.sandboxed_bash_argv ->
    # Security::Sandbox.wrap_argv/wrap_env), so a config-supplied formatter
    # command is confined to the workspace exactly like a model-issued shell
    # call, never a bare unsandboxed Kernel#system escape hatch. Runs in its
    # own process group so a timeout can TERM/KILL the whole subtree.
    def spawn_formatter(command, expanded_path)
      script = "#{command} #{Shellwords.escape(expanded_path)}"
      cwd    = Workspace.primary_root
      env, *argv = Tools::ShellTool.sandboxed_bash_argv(script, cwd: cwd)

      rd, wr = IO.pipe
      pid = Process.spawn(env, *argv, chdir: cwd, pgroup: true, in: File::NULL, out: wr, err: wr)
      wr.close
      reader = Thread.new { read_capped(rd, MAX_NOTE_OUTPUT_BYTES) }
      timed_out = false
      watchdog = Thread.new do
        sleep TIMEOUT_SECONDS
        timed_out = true
        kill_group(pid)
      end

      _pid, status = Process.waitpid2(pid)
      watchdog.kill
      { output: reader.value, exit_code: status&.exitstatus, timed_out: timed_out }
    rescue StandardError => e
      { output: e.message, exit_code: nil, timed_out: false, spawn_error: true }
    ensure
      rd&.close unless rd&.closed?
      wr&.close unless wr&.closed?
    end

    def kill_group(pid)
      Process.kill("TERM", -pid)
      sleep 0.3
      Process.kill("KILL", -pid)
    rescue Errno::ESRCH, Errno::EPERM
      nil
    end

    # Bounded read of the formatter's merged stdout+stderr — enough for a
    # short diagnostic, never an unbounded firehose held in memory.
    def read_capped(io, cap)
      buf = +""
      begin
        loop do
          chunk = io.readpartial(65_536)
          buf << chunk if buf.bytesize < cap
        end
      rescue IOError, Errno::EBADF
        nil
      end
      Util::Output.scrub_utf8(buf.byteslice(0, cap) || buf)
    end

    def success?(outcome)
      !outcome[:spawn_error] && !outcome[:timed_out] && outcome[:exit_code].to_i.zero?
    end

    def note_for(command:, display_path:, outcome:, changed:)
      unless success?(outcome)
        return failure_note(command: command, display_path: display_path, outcome: outcome, changed: changed)
      end
      return nil unless changed

      "[formatter] `#{command}` reformatted #{display_path}"
    end

    def failure_note(command:, display_path:, outcome:, changed:)
      reason = if outcome[:spawn_error]
                 "failed to start"
               elsif outcome[:timed_out]
                 "timed out after #{TIMEOUT_SECONDS}s"
               else
                 "exited #{outcome[:exit_code]}"
               end
      # A failing formatter (e.g. rubocop -A hitting a remaining unfixable
      # offense) may still have partially rewritten the file before failing —
      # don't claim "not reformatted" when it demonstrably changed something.
      disposition = if changed
                      "the file may have been partially modified before it failed"
                    else
                      "the file was NOT reformatted"
                    end
      lines = outcome[:output].to_s.strip.lines
      Util::Preview.truncate_lines!(lines, MAX_NOTE_OUTPUT_LINES)
      tail = lines.join.strip
      note = "[formatter] `#{command}` #{reason} on #{display_path} " \
             "— the write/edit itself still succeeded; #{disposition}."
      tail.empty? ? note : "#{note}\n#{tail}"
    end
  end
end
