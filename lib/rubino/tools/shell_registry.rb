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
      end

      def initialize
        @entries = {}
        @mutex   = Mutex.new
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
        pid = Process.spawn(command, chdir: cwd, pgroup: true, in: in_rd, out: wr, err: wr)
        wr.close
        in_rd.close

        entry = Entry.new(
          id:          new_id,
          command:     command,
          cwd:         cwd,
          pid:         pid,
          pgid:        pid,
          wait_thr:    Process.detach(pid),
          buffer:      +"",
          mutex:       Mutex.new,
          started_at:  Time.now,
          read_offset: 0,
          stdin:       in_wr
        )
        entry.reader_thr = Thread.new { drain_into(entry, rd) }

        @mutex.synchronize { @entries[entry.id] = entry }
        entry
      end

      def find(id)
        @mutex.synchronize { @entries[id] }
      end

      def remove(id)
        entry = @mutex.synchronize { @entries.delete(id) }
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
        if entry.wait_thr.alive?
          :running
        else
          entry.wait_thr.value.success? ? :completed : :failed
        end
      end

      def exit_code(entry)
        return nil if entry.wait_thr.alive?
        entry.wait_thr.value.exitstatus
      end

      private

      def new_id
        "bg_#{SecureRandom.hex(4)}"
      end

      # Single-reader pattern: only this thread writes to entry.buffer, the
      # mutex protects only against concurrent reads from shell_output_tool.
      def drain_into(entry, rd)
        rd.each_line do |chunk|
          entry.mutex.synchronize do
            entry.buffer << chunk
            overflow = entry.buffer.bytesize - RING_BYTES
            if overflow.positive?
              entry.buffer  = entry.buffer.byteslice(overflow..) || +""
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
