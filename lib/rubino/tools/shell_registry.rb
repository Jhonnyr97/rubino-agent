# frozen_string_literal: true

require "securerandom"
require "open3"

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

      Entry = Struct.new(
        :id, :command, :cwd, :pid, :pgid, :wait_thr, :reader_thr,
        :buffer, :mutex, :started_at, :read_offset, :stdin,
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
      def spawn(command:, cwd:)
        rd, wr = IO.pipe
        # Writable stdin pipe: the agent feeds answers to interactive prompts
        # (Y/N, "select region", apt-style) via the `shell_input` tool, which
        # writes to `in_wr`. Line-oriented `read`/prompt commands consume this
        # fine; full-screen TTY programs (vim, REPLs that require [ -t 0 ]) are
        # out of scope for a plain pipe.
        in_rd, in_wr = IO.pipe
        # pgroup: true → child becomes leader of a new process group whose
        # pgid == child pid. Lets shell_kill send SIGTERM to the whole tree.
        # bash -o pipefail keeps this path consistent with the foreground
        # shell: a mid-pipeline crash surfaces as the exit status (#156).
        pid = Process.spawn("bash", "-o", "pipefail", "-c", command,
                            chdir: cwd, pgroup: true, in: in_rd, out: wr, err: wr)
        wr.close
        in_rd.close

        entry = Entry.new(
          id: new_id,
          command: command,
          cwd: cwd,
          pid: pid,
          pgid: pid,
          wait_thr: Process.detach(pid),
          buffer: +"",
          mutex: Mutex.new,
          started_at: Time.now,
          read_offset: 0,
          stdin: in_wr
        )
        entry.reader_thr = Thread.new { drain_into(entry, rd) }

        @mutex.synchronize do
          @entries[entry.id] = entry
          refresh_pgid_snapshot
        end
        entry
      end

      def find(id)
        @mutex.synchronize { @entries[id] }
      end

      # True when at least one background shell has been started this session
      # (and not yet removed). The session-stable signal #313 gates the
      # shell-management tools on: a normal turn with no background shell never
      # ships shell_input/shell_output/shell_tail/shell_kill. Flips at most once
      # per session (when the first background shell is spawned), so the cached
      # tool prefix stays stable across ordinary turns.
      def any?
        @mutex.synchronize { !@entries.empty? }
      end

      def remove(id)
        entry = @mutex.synchronize do
          e = @entries.delete(id)
          refresh_pgid_snapshot
          e
        end
        close_stdin(entry) if entry
        entry
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
        io.close if io && !io.closed?
      rescue IOError
        # already closed
      end

      # Reads accumulated bytes since the last `read_new` call. Returns the
      # full snapshot if `since` is nil. Thread-safe.
      def read_new(entry)
        entry.mutex.synchronize do
          snapshot = entry.buffer.byteslice(entry.read_offset..) || ""
          entry.read_offset = entry.buffer.bytesize
          snapshot
        end
      end

      def read_all(entry)
        entry.mutex.synchronize { entry.buffer.dup }
      end

      def status(entry)
        return :running if entry.wait_thr.alive?

        code = entry.wait_thr.value.exitstatus
        code && ShellTool.success_exit?(code) ? :completed : :failed
      end

      def exit_code(entry)
        return nil if entry.wait_thr.alive?

        entry.wait_thr.value.exitstatus
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
        @pgid_snapshot = (@entries.values.map(&:pgid) + @fg_pgids.keys).uniq.freeze
      end

      def signal_group(sig, pgid)
        Process.kill(sig, -pgid)
      rescue Errno::ESRCH, Errno::EPERM
        # Already dead, already reaped, or not ours — nothing to do.
      end

      def new_id
        "bg_#{SecureRandom.hex(4)}"
      end

      # Single-reader pattern: only this thread writes to entry.buffer, the
      # mutex protects only against concurrent reads from shell_output_tool.
      def drain_into(entry, rd)
        rd.each_line do |chunk|
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
          chunk = Util::Output.scrub_utf8(chunk)
          entry.mutex.synchronize do
            entry.buffer << chunk
            overflow = entry.buffer.bytesize - RING_BYTES
            if overflow.positive?
              entry.buffer = entry.buffer.byteslice(overflow..) || +""
              # Reset read_offset proportionally so the next read still sees
              # only fresh bytes, not whatever survived the trim.
              entry.read_offset = [entry.read_offset - overflow, 0].max
            end
          end
        end
      rescue IOError, Errno::EBADF
        # pipe closed — process exited
      ensure
        rd.close unless rd.closed?
      end
    end
  end
end
