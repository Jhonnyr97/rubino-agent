# frozen_string_literal: true

require "securerandom"
require "fileutils"
require "open3"
require "pty"
require "shellwords"
require "io/console"

module Rubino
  module Tools
    # Process-wide registry for shell commands started with `run_in_background`.
    # Each entry owns a pgid (process group), a reader thread that drains
    # stdout+stderr into an in-memory ring buffer, and the wait_thr for exit.
    #
    # The registry survives a single CLI/server process — it is intentionally
    # NOT persisted to disk. Background shells die with the agent process.
    class ShellRegistry
      RING_BYTES = 256 * 1024 # cap per run; older bytes are dropped

      # Cap on bytes read from the log file in a single `read_all` call
      # (the full file is always on disk for user tailing; this bounds in-memory
      # reads so a days-long server log doesn't OOM the process).
      LOG_READ_MAX_BYTES = 50 * 1024 * 1024 # 50 MB

      # A backgrounded command that FINISHES before the next turn used to be
      # dropped from the registry the moment a reader (shell_output/tail/kill)
      # saw it non-running — which also collapsed `any?` to false, so the
      # shell-management tools vanished from the schema next turn and the
      # model could never fetch a short bg command's captured output (#78).
      # Instead a finished entry is RETIRED: it stays in the registry (its
      # buffer + exit status intact, retrievable by shell_output) and `any?`
      # keeps the tools exposed, until it is read again OR these bounds reap
      # it. RETIRED_TTL caps how long a finished-but-unread entry lingers;
      # MAX_RETIRED caps how many we keep at once (oldest-retired evicted
      # first) so the registry stays bounded across a long session.
      RETIRED_TTL = 300 # seconds a finished, unread bg shell stays retrievable
      MAX_RETIRED = 16  # most retired entries retained at once

      Entry = Struct.new(
        :id, :command, :cwd, :pid, :pgid, :wait_thr, :reader_thr,
        :buffer, :mutex, :started_at, :read_offset, :stdin, :retired_at,
        # sink: the parent's background_sink captured at spawn (thread-locals
        # don't propagate to the reader thread, so we stash it like a subagent
        # does). notified: fire-once guard so a finished bg shell pushes its
        # completion notice exactly once (US-5; avoids the Claude-Code
        # duplicate-reminder leak).
        :sink, :notified,
        # pty: true when the child runs on a real pseudo-terminal (interactive
        # mode) rather than plain pipes — changes how the reader EOFs (EIO vs
        # IOError) and how stdin is closed (EOT vs fd close, since closing a PTY
        # master SIGHUPs the child). #591-adjacent: kept a plain field, no logic.
        :pty,
        # stopped: set when the shell was DELIBERATELY terminated from the UI
        # (/stop) so #status reports :stopped, not :failed — a SIGTERM/SIGKILL
        # exit is "non-success" but it's a user stop, not a crash.
        :stopped,
        # owner_subagent_id: the sa_* id of the background subagent that opened
        # this shell (nil when the human / main agent did). Captured at spawn from
        # Rubino.current_subagent_id (thread-local). Lets stopping a parent
        # subagent cascade-kill its child shells — mirrors Hermes' process_registry
        # task_id + kill_all(task_id).
        :owner_subagent_id,
        # File-based log (persists beyond process, tail-able by the user).
        # log_file is the WRITER handle (owned by the reader thread); readers
        # open their own handles so file positions never conflict.
        :log_path, :log_file, :file_read_offset,
        keyword_init: true
      )

      class << self
        def instance
          @instance ||= new
        end

        # Test seam: drop the process-wide registry between examples so the
        # situational shell-tool gate (#313) starts each spec with no background
        # shell. Mirrors BackgroundTasks.reset!.
        def reset!
          @instance = nil
        end
      end

      def initialize
        @entries = {}
        @mutex   = Mutex.new
        # Live FOREGROUND shell process groups, keyed by pgid. A foreground
        # shell's pgid otherwise lives only in the ShellTool#execute_foreground
        # stack frame of the (sub)agent thread that started it — so on
        # parent-death there is nothing process-wide to reap it and it
        # reparents to init as an orphan (MED-2). Tracking it here lets
        # #kill_all_groups SIGTERM/SIGKILL it synchronously on teardown.
        @fg_pgids = {}
        # Lock-free, atomically-swapped snapshot of every live shell pgid
        # (background entries + tracked foreground pgids). The SIGTERM/SIGHUP
        # teardown trap (#478) reaps the child groups, but it CANNOT take the
        # mutex above — Ruby forbids Mutex#synchronize from a trap context
        # (ThreadError). The writers always rebuild this frozen Array UNDER the
        # mutex; the trap reads it with a single, lock-free ivar read (an atomic
        # reference load in MRI) and never iterates a structure another thread
        # is mutating. See #kill_all_groups_trap_safe.
        @pgid_snapshot = [].freeze
      end

      # Track a live foreground shell process group so teardown can reap it.
      def register_pgid(pgid)
        @mutex.synchronize do
          @fg_pgids[pgid] = true
          refresh_pgid_snapshot
        end
        pgid
      end

      # Drop a foreground shell process group once its own thread has reaped it.
      def unregister_pgid(pgid)
        @mutex.synchronize do
          @fg_pgids.delete(pgid)
          refresh_pgid_snapshot
        end
      end

      # Spawns `command` detached in its own process group so a single kill
      # takes out the whole subtree. Returns the new entry.
      def spawn(command:, cwd:, pty: false)
        # Capture the parent's notification sink on the CALLING thread (the turn
        # thread). The reader thread below can't read Rubino.background_sink —
        # thread-locals don't propagate — so a finished bg shell would notify
        # nothing (US-5 lost-completion). Stash it like a subagent does. Same for
        # the owning subagent id (thread-local), so stopping that subagent can
        # cascade-kill this shell.
        sink  = Rubino.background_sink
        owner = Rubino.current_subagent_id
        # I/O setup differs by mode but the registry bookkeeping below is shared:
        # pipe (default, non-interactive) vs PTY (interactive — real terminal).
        reader_io, stdin_io, pid = pty ? spawn_pty(command, cwd) : spawn_pipe(command, cwd)

        # Per-run log file so the user can tail -f it from another terminal
        # (like Claude Code's task logs). The reader thread tees every chunk
        # here; readers open their own handles.
        entry_id = new_id
        log_path, log_file = open_log_file(entry_id)

        entry = Entry.new(
          id: entry_id,
          command: command,
          cwd: cwd,
          pid: pid,
          pgid: pid,
          wait_thr: Process.detach(pid),
          buffer: +"",
          mutex: Mutex.new,
          started_at: Time.now,
          read_offset: 0,
          stdin: stdin_io,
          sink: sink,
          owner_subagent_id: owner,
          notified: false,
          pty: pty,
          log_path: log_path,
          log_file: log_file,
          file_read_offset: 0
        )
        entry.reader_thr = Thread.new { drain_into(entry, reader_io) }

        @mutex.synchronize do
          @entries[entry.id] = entry
          refresh_pgid_snapshot
        end
        entry
      end

      # Pipe-backed spawn (default): a writable stdin pipe lets the agent feed
      # answers to line-oriented prompts (Y/N, apt-style) via `shell_input`;
      # stdout+stderr merge into one read pipe. Full-screen TTY programs (vim,
      # REPLs that require `[ -t 0 ]`, getpass on /dev/tty) are out of scope for
      # a plain pipe — those want PTY mode (#spawn_pty). Returns [reader, stdin, pid].
      #
      # pgroup: true → the child leads a new process group (pgid == child pid),
      # so shell_kill SIGTERMs the whole tree. bash -o pipefail mirrors the
      # foreground shell (a mid-pipeline crash surfaces as the exit status, #156).
      # OS write-jail (#290/#544): the argv+env go through the SAME
      # ShellTool.sandboxed_bash_argv the foreground uses, so a backgrounded
      # write is jailed identically (the launcher exec's bash in-place, preserving
      # pgroup/pipes/cwd). Empty prefix when the sandbox is off ⇒ unchanged.
      def spawn_pipe(command, cwd)
        rd, wr = IO.pipe
        in_rd, in_wr = IO.pipe
        pid = Process.spawn(*ShellTool.sandboxed_bash_argv(command, cwd: cwd),
                            chdir: cwd, pgroup: true, in: in_rd, out: wr, err: wr)
        wr.close
        in_rd.close
        [rd, in_wr, pid]
      end

      # PTY-backed spawn (interactive): the child runs on a REAL pseudo-terminal,
      # so `[ -t 0 ]`, tty-aware tools, y/N prompts and /dev/tty password reads
      # all work where a pipe can't. PTY.spawn sets up the controlling terminal
      # (setsid), making the child a session leader → pgid == pid, so the same
      # pgroup hard-kill applies. The master is FULL-DUPLEX: the same terminal is
      # both the output reader and the stdin writer. cwd is baked into the script
      # (PTY.spawn takes no chdir option); the sandbox argv/env still come from
      # the shared helper. Returns [master_reader, master_writer, pid]. Mirrors
      # Hermes' ptyprocess path (tools/process_registry.py spawn_local use_pty).
      def spawn_pty(command, cwd)
        # cwd on its OWN line, NOT a `cd && (#{command})` subshell: a command
        # ending in a `#`-comment would otherwise swallow the closing paren and
        # break. `|| exit 127` still aborts before running in the wrong dir,
        # mirroring the pipe path's `chdir:` failure.
        script = "cd #{Shellwords.escape(cwd)} || exit 127\n#{command}"
        master_r, master_w, pid = PTY.spawn(*ShellTool.sandboxed_bash_argv(script, cwd: cwd))
        # A fresh PTY is 0x0; give it a sane size so `tput cols`, pagers and
        # progress bars don't misbehave (the attach view resizes to the real
        # terminal later). Best-effort — never fail a spawn over winsize.
        begin
          master_w.winsize = [40, 120]
        rescue StandardError
          nil
        end
        [master_r, master_w, pid]
      end

      def find(id)
        @mutex.synchronize { @entries[id] }
      end

      # True when at least one background shell is RUNNING or has finished but is
      # still retained (retired, unread, within TTL — see #retire). The
      # session-stable signal #313 gates the shell-management tools on this: a
      # normal turn with no background shell never ships
      # shell_input/shell_output/shell_tail/shell_kill, but a SHORT bg command
      # that finished before the next turn keeps shell_output exposed so the
      # model can still fetch its captured output (#78). Prunes stale retired
      # entries first so the gate closes once nothing is reachable.
      def any?
        @mutex.synchronize do
          prune_retired
          !@entries.empty?
        end
      end

      def remove(id)
        entry = @mutex.synchronize do
          e = @entries.delete(id)
          refresh_pgid_snapshot
          e
        end
        if entry
          close_stdin(entry)
          close_log_file(entry)
        end
        entry
      end

      # Retires a FINISHED background shell instead of dropping it (#78): the
      # entry stays in the registry — its captured output + exit status intact
      # and retrievable by a later shell_output — and `any?` keeps the
      # shell-management tools exposed, so a short bg command's output is still
      # reachable on the next turn. The process is already dead, so its pgid is
      # cleared from the teardown snapshot and its stdin closed. Bounded by
      # RETIRED_TTL / MAX_RETIRED (pruned here and in #any?). Stamps retired_at
      # on the first retire and is idempotent — a second read of a retired entry
      # keeps the original timestamp so a re-read can't extend its lifetime
      # indefinitely. No-op for an unknown or still-running id.
      def retire(id)
        @mutex.synchronize do
          entry = @entries[id]
          return nil unless entry
          return entry if entry.retired_at # already retired — keep original TTL clock

          entry.retired_at = Time.now
          close_stdin(entry)    # process is gone; release its stdin pipe
          refresh_pgid_snapshot # a retired (dead) shell drops out of the teardown set
          prune_retired
          entry
        end
      end

      # Writes `text` to the background process's stdin (with a trailing
      # newline unless `enter: false`) — the "press Enter to answer a prompt"
      # path. Returns the number of bytes written, or raises if stdin is gone.
      def write_input(entry, text, enter: true)
        io = entry.stdin
        raise IOError, "stdin already closed" if io.nil? || io.closed?

        payload = enter ? "#{text}\n" : text.to_s
        io.write(payload)
        io.flush
        payload.bytesize
      end

      # Closes the write end of the child's stdin (sends EOF). Idempotent.
      def close_stdin(entry)
        io = entry&.stdin
        return if io.nil? || io.closed?

        # On a PTY, closing the master fd SIGHUPs the child. So while the child is
        # ALIVE, signal EOF without killing by sending EOT (Ctrl-D) — a line reader
        # in canonical mode at line-start treats it as end-of-input (a raw-mode
        # child sees a literal byte; that's out of scope). Once the child is GONE,
        # there is nothing to EOF and writing the master raises Errno::EIO — so
        # close the master fd instead, which also reclaims it (it is a SEPARATE fd
        # from the reader's, otherwise leaked until GC).
        if entry&.pty && running?(entry)
          io.write("\x04")
          io.flush
        else
          io.close
        end
      rescue IOError, Errno::EIO, Errno::EBADF
        # already closed / child gone — nothing to flush
      end

      # Reads accumulated bytes since the last `read_new` call from the ON-DISK
      # log file (not the ring buffer). Thread-safe: the mutex guards the offset
      # update so concurrent readers don't skip bytes.
      def read_new(entry)
        entry.mutex.synchronize do
          path = entry.log_path
          return "" unless path && File.exist?(path)

          File.open(path) do |f|
            f.seek(0, IO::SEEK_END)
            total = f.pos
            return "" if entry.file_read_offset >= total

            f.seek(entry.file_read_offset)
            data = f.read(total - entry.file_read_offset)
            entry.file_read_offset = total
            data
          end
        end
      end

      # Reads the FULL on-disk log file, capped at LOG_READ_MAX_BYTES so a
      # days-long server log doesn't OOM the process. The full file is always
      # on disk for the user to tail.
      def read_all(entry)
        path = entry.log_path
        return "" unless path && File.exist?(path)

        size = File.size(path)
        if size <= LOG_READ_MAX_BYTES
          File.read(path)
        else
          File.open(path) do |f|
            f.seek(size - LOG_READ_MAX_BYTES)
            f.read
          end
        end
      end

      # Short grace after the leader exits to let the reader thread flush the
      # final buffered chunk to the log file — mirroring the foreground's
      # DETACHED_DRAIN_GRACE. A shell_output right after completion must still
      # return the tail.
      DRAIN_GRACE = 0.1

      # THE single liveness oracle for a background shell — "is the work this
      # entry represents still running?". Every surface (status, the running
      # set, the kill/input guards, the UI cards) routes through here so they
      # can never disagree about whether a shell is alive.
      #
      # Liveness is derived from the LEADER PROCESS only (the wait_thr from
      # Process.detach). The reader thread is NOT part of the liveness signal:
      # tying completion to whether the stdout pipe is still open caused the
      # real bug where a finished command whose detached child holds the pipe
      # was stuck "running" forever — the model could never see completion and
      # had to KILL it. The reader thread keeps DRAINING residual/child output
      # into the log; it just no longer GATES completion. A short #drain_tail
      # grace in #status / #exit_code ensures the final chunk is flushed before
      # those report :completed/:failed.
      def running?(entry)
        return false unless entry

        entry.wait_thr&.alive? || false
      end

      def status(entry)
        return :running if running?(entry)
        return :stopped if entry.stopped

        drain_tail(entry)
        code = entry.wait_thr.value.exitstatus
        code && ShellTool.success_exit?(code) ? :completed : :failed
      end

      def exit_code(entry)
        return nil if running?(entry)

        drain_tail(entry)
        entry.wait_thr.value.exitstatus
      end

      # Give the reader thread a short window to flush the final readpartial
      # chunk to the log file after the leader has exited, so a shell_output
      # call right after status flips to :completed still sees the tail.
      def drain_tail(entry)
        entry.reader_thr&.join(DRAIN_GRACE) if entry.reader_thr&.alive?
      end

      # The RUNNING background shells (not yet exited, not retired) — the set the
      # picker/cards surface as live "background work" alongside subagents.
      def running_entries
        @mutex.synchronize { @entries.values.select { |e| e.retired_at.nil? && running?(e) } }
      end

      # Running PLUS retired (finished-but-retained) shells — the set shown in the
      # /agents list + /status count, mirroring how finished subagents linger.
      def listable_entries
        @mutex.synchronize { @entries.values.dup }
      end

      # Cascade-stop: terminate every RUNNING shell a subagent opened — its child
      # background work, killed when the parent subagent is stopped. Mirrors
      # Hermes' process_registry kill_all(task_id). Returns the count terminated.
      def terminate_owned_by(subagent_id)
        return 0 unless subagent_id

        owned = @mutex.synchronize do
          @entries.values.select do |e|
            e.owner_subagent_id == subagent_id && e.retired_at.nil? && running?(e)
          end
        end
        owned.each { |e| terminate(e) }
        owned.size
      end

      # SIGTERM→grace→SIGKILL the process group, then retire so the captured
      # output stays retrievable (shares the kill contract with shell_kill). The
      # single per-shell stop seam the UI (/stop, picker) routes through.
      def terminate(entry, grace: 2)
        entry.stopped = true # a UI /stop ⇒ #status reports :stopped, not :failed
        return retire(entry.id) unless running?(entry)

        signal_group("TERM", entry.pgid)
        grace.times do
          break unless running?(entry)

          sleep 1
        end
        signal_group("KILL", entry.pgid) if running?(entry)
        retire(entry.id)
      end

      # Synchronous teardown reaper (MED-2): SIGTERM every live shell process
      # group this session owns — the background ENTRIES and the tracked
      # FOREGROUND pgids — give them a brief grace, then SIGKILL any straggler.
      # Mirrors the Python Hermes `_kill_process` (os.killpg SIGTERM → wait →
      # SIGKILL). Called from BackgroundTasks#cancel_all so EVERY parent-death
      # edge (clean quit `ensure`, HUP/TERM trap, REPL break) reaps the child
      # shells the cooperative cancel token alone can't reach before the process
      # exits and the shells reparent to init. Returns the pgids it signalled.
      #
      # TRAP-SAFE (#478): reads the lock-free @pgid_snapshot — never
      # Mutex#synchronize, which Ruby forbids from a signal-trap context
      # (ThreadError). So the SIGTERM/SIGHUP teardown trap can call this
      # directly. Process.kill and sleep are both async-signal-safe.
      def kill_all_groups(grace: 0.5)
        pgids = @pgid_snapshot
        return pgids if pgids.empty?

        pgids.each { |pgid| signal_group("TERM", pgid) }
        sleep(grace) if grace.positive?
        pgids.each { |pgid| signal_group("KILL", pgid) }
        pgids
      end

      private

      # Rebuild the lock-free pgid snapshot from the authoritative maps and swap
      # it in with a single atomic ivar assignment. ALWAYS called UNDER @mutex by
      # a writer, so it observes a consistent map and serializes against other
      # writers; the trap-side reader in #kill_all_groups never locks. The new
      # Array is frozen so a reader can't see a half-built collection.
      def refresh_pgid_snapshot
        live_pgids = @entries.values.reject(&:retired_at).map(&:pgid)
        @pgid_snapshot = (live_pgids + @fg_pgids.keys).uniq.freeze
      end

      # Bounds the retained-finished set (#78): drop retired entries older than
      # RETIRED_TTL, then evict the oldest-retired ones until at most MAX_RETIRED
      # remain. Running entries are never touched. Always called UNDER @mutex.
      def prune_retired
        retired = @entries.values.select(&:retired_at)
        return if retired.empty?

        now = Time.now
        stale = retired.select { |e| now - e.retired_at > RETIRED_TTL }
        survivors = retired - stale
        overflow = survivors.sort_by(&:retired_at).first([survivors.size - MAX_RETIRED, 0].max)
        (stale + overflow).each do |e|
          @entries.delete(e.id)
          close_stdin(e)
          close_log_file(e)
          delete_log_file(e)
        end
        refresh_pgid_snapshot
      end

      def signal_group(sig, pgid)
        Process.kill(sig, -pgid)
      rescue Errno::ESRCH, Errno::EPERM
        # Already dead, already reaped, or not ours — nothing to do.
      end

      def new_id
        "bg_#{SecureRandom.hex(4)}"
      end

      # ── File-based log helpers ──────────────────────────────────────────

      def logs_base_dir
        # Log files live under the workspace so the OS write-jail allows them
        # (~/.rubino is protected — same reason shell can't rm skills there).
        # The user can tail -f them from another terminal.
        root = Rubino::Workspace.primary_root
        File.join(root, ".rubino", "logs", "bg")
      rescue StandardError
        File.expand_path("~/.rubino/logs/bg")
      end

      # Opens a per-run log file for writing. Returns [path, io].
      def open_log_file(entry_id)
        dir = logs_base_dir
        FileUtils.mkdir_p(dir)
        path = File.join(dir, "#{entry_id}.log")
        file = File.open(path, "w") # rubocop:disable Style/FileOpen -- sync-flushed for crash safety
        file.sync = true
        [path, file]
      rescue StandardError => e
        # Best-effort: a missing log file must never block a shell spawn.
        Rubino.logger&.warn(msg: "Failed to open bg-shell log file: #{e.message}")
        [nil, nil]
      end

      # Idempotent close of the writer handle.
      def close_log_file(entry)
        file = entry&.log_file
        return if file.nil? || file.closed?

        file.close
      rescue IOError, Errno::EBADF
        nil
      end

      # Deletes the log file from disk (called on prune / retire).
      def delete_log_file(entry)
        path = entry&.log_path
        return unless path && File.exist?(path)

        File.delete(path)
      rescue StandardError
        nil
      end

      # Single-reader pattern: only this thread writes to entry.buffer AND the
      # log file. The mutex protects against concurrent reads from shell_output_tool.
      #
      # Drains with readpartial (NOT each_line), mirroring the foreground shell
      # drain (shell_tool.rb ~522). each_line only yields on \n/EOF, so \r-progress
      # bars, spinners, and un-terminated prompts were buffered and never teed to
      # the log until a newline or exit — shell_tail/shell_output falsely reported
      # "no new output". readpartial emits every chunk immediately.
      def drain_into(entry, rd)
        loop do
          raw = rd.readpartial(65_536)
          # Scrub to valid UTF-8 AT THE CAPTURE SEAM, mirroring the FOREGROUND
          # shell (ShellTool drains through Util::Output.scrub_utf8). A binary /
          # latin-1 background process (`head -c … /dev/urandom &`, `cat *.png &`)
          # writes bytes tagged UTF-8 but invalid; left raw in the ring buffer
          # they blow up JSON.generate (the LLM request) + the SQLite driver when
          # `shell_output` returns them, and the tool row never persists — the
          # model loses the record on --resume. Cleaning here means the buffer is
          # already safe for every reader (read_new / read_all). Terminal-escape
          # neutralization for what reaches the screen is a separate render-seam
          # concern (CLI#safe on the close-row metric / write_body_lines).
          chunk = Util::Output.scrub_utf8(raw)
          entry.mutex.synchronize do
            entry.buffer << chunk
            overflow = entry.buffer.bytesize - RING_BYTES
            if overflow.positive?
              entry.buffer = entry.buffer.byteslice(overflow..) || +""
              # Reset read_offset proportionally so the next read still sees
              # only fresh bytes, not whatever survived the trim.
              entry.read_offset = [entry.read_offset - overflow, 0].max
            end
            # Tee to the on-disk log file (user can tail -f it).
            entry.log_file.write(chunk) if entry.log_file && !entry.log_file.closed?
          end
        end
      rescue EOFError, Errno::EBADF, Errno::EIO
        # End of stream = the process exited. A pipe signals EOF then raises
        # EOFError/IOError; a PTY master instead raises Errno::EIO once the child
        # is gone. Both mean "reader done", same completion path below.
      ensure
        rd.close unless rd.closed?
        # Close the writer handle so the file is complete on disk.
        close_log_file(entry)
        # The reader thread ends exactly when the pipe closes = the process
        # exited (normal, crash, or shell_kill). Push a completion notice to the
        # parent so a finished background SHELL auto-wakes the model the same way
        # a finished background SUBAGENT does — without this, a finished bg shell
        # surfaced NOTHING (US-5 lost notification). Fire-once.
        notify_completion(entry)
      end

      # Fire-once completion notice for a finished background shell, routed
      # through the captured parent sink (drained at Agent::Loop's top-of-turn,
      # like a subagent's `[background-task]` notice).
      def notify_completion(entry)
        fire = entry.mutex.synchronize do
          next false if entry.notified

          entry.notified = true
        end
        return unless fire
        return unless entry.sink

        code = begin
          entry.wait_thr&.value&.exitstatus
        rescue StandardError
          nil
        end
        status = code.nil? || code.zero? ? "completed" : "exited (code #{code})"
        entry.sink.push_notice(
          "[background-shell] Shell #{entry.id} (`#{entry.command}`) #{status}. " \
          "Read its output with `shell_output run_id=#{entry.id}`."
        )
      rescue StandardError
        # Notification is best-effort — never let it crash the reader thread.
        nil
      end
    end
  end
end
