# frozen_string_literal: true

require "securerandom"
require "json"

module Rubino
  module Session
    # Thin CRUD wrapper over the `sessions` table. All session persistence
    # goes through this class; callers should not touch the dataset directly.
    #
    # Notes:
    # - #find supports prefix matching on the UUID so short ids from the CLI
    #   resolve to a full session row.
    # - #latest_active is used to resume the most recently touched session.
    # - #destroy! cascades manually to events, tool_calls, messages,
    #   session_summaries and runs inside a single transaction (no FK cascade
    #   in schema; the runs FK would otherwise block the session delete).
    class Repository
      def initialize(db: nil)
        @db = db || Rubino.database.db
      end

      # Creates a new session and returns its record. +cwd+ stamps the launch
      # directory so resume can be scoped per-cwd (r5 MF-4 / C-1); defaults to the
      # current workspace primary root so every session records where it started.
      def create(source:, model: nil, provider: nil, title: nil, parent_session_id: nil, cwd: default_cwd)
        now = Time.now.utc.iso8601
        id = generate_id

        @db[:sessions].insert(
          id: id,
          parent_session_id: parent_session_id,
          source: source,
          model: model,
          provider: provider,
          title: title,
          status: "active",
          owner_pid: Process.pid,
          cwd: cwd,
          message_count: 0,
          token_count: 0,
          created_at: now,
          updated_at: now
        )

        find(id)
      end

      # Builds an UNSAVED session record (in-memory only) with a real id, so the
      # CLI can open `chat` without persisting a row until the user actually
      # sends a message (#144). The row is inserted lazily by #persist! on the
      # first message; a session the user opens and immediately exits never
      # touches the DB, so `/sessions` stays free of (untitled)/0-msg junk.
      def build(source:, model: nil, provider: nil, title: nil, parent_session_id: nil, cwd: default_cwd)
        now = Time.now.utc.iso8601
        {
          id: generate_id,
          parent_session_id: parent_session_id,
          source: source,
          model: model,
          provider: provider,
          title: title,
          status: "active",
          cwd: cwd,
          message_count: 0,
          token_count: 0,
          created_at: now,
          updated_at: now,
          persisted: false
        }
      end

      # Inserts a session row built by #build if it isn't already in the DB.
      # Idempotent: a no-op once persisted (the common per-message path checks
      # this first). Returns the (now persisted) session record.
      def persist!(session)
        return session if session[:persisted] || persisted?(session[:id])

        @db[:sessions].insert(
          id: session[:id],
          parent_session_id: session[:parent_session_id],
          source: session[:source],
          model: session[:model],
          provider: session[:provider],
          title: session[:title],
          status: session[:status] || "active",
          owner_pid: Process.pid,
          cwd: session[:cwd],
          message_count: 0,
          token_count: 0,
          created_at: session[:created_at] || Time.now.utc.iso8601,
          updated_at: Time.now.utc.iso8601
        )
        session[:persisted] = true
        session
      end

      # True when a row with this id exists in the sessions table.
      def persisted?(id)
        return false if id.nil?

        !@db[:sessions].where(id: id).empty?
      end

      # Finds a session by ID (supports prefix matching)
      def find(id)
        @db[:sessions].where(Sequel.like(:id, "#{id}%")).first
      end

      # Resolves a user-supplied query to a session: tries ID prefix first
      # (handles "abc12345" style short IDs), then falls back to a case-
      # insensitive substring match across the 50 most recent sessions —
      # against the title AND the full first user message. The stored title
      # is truncated (~60 chars), so a memorable word from the TAIL of a long
      # first prompt would otherwise silently fail to resume (#70).
      # Returns the session row or nil. Centralised so the CLI Runner and
      # the TUI history loader agree on what `--resume <query>` accepts.
      #
      # Raises AmbiguousSessionError when >1 session matches, so the CLI
      # can show the candidates instead of silently picking the first row
      # — see issue triaged from the audit (#116).
      def find_by_id_or_title(query)
        return nil if query.nil? || query.to_s.empty?

        id_matches = @db[:sessions].where(Sequel.like(:id, "#{query}%")).all
        if id_matches.size > 1
          raise AmbiguousSessionError.new(query, id_matches)
        elsif id_matches.size == 1
          return id_matches.first
        end

        needle = query.to_s.downcase
        title_matches = list(limit: 50).select do |s|
          s[:title]&.downcase&.include?(needle) ||
            first_user_message(s[:id])&.downcase&.include?(needle)
        end
        if title_matches.size > 1
          raise AmbiguousSessionError.new(query, title_matches)
        elsif title_matches.size == 1
          return title_matches.first
        end

        nil
      end

      # Lists sessions with optional filters
      def list(limit: 20, status: nil, search: nil)
        dataset = @db[:sessions].order(Sequel.desc(:created_at), Sequel.desc(Sequel.lit("rowid"))).limit(limit)
        dataset = dataset.where(status: status) if status
        dataset = dataset.where(Sequel.like(:title, "%#{search}%")) if search && !search.empty?
        dataset.all
      end

      # Updates a session's attributes
      def update(id, **attrs)
        attrs[:updated_at] = Time.now.utc.iso8601
        @db[:sessions].where(id: id).update(attrs)
      end

      # Increments message count
      def increment_message_count!(id)
        @db[:sessions].where(id: id).update(
          message_count: Sequel[:message_count] + 1,
          updated_at: Time.now.utc.iso8601
        )
      end

      # Updates token count
      def update_token_count!(id, token_count)
        @db[:sessions].where(id: id).update(
          token_count: token_count,
          updated_at: Time.now.utc.iso8601
        )
      end

      # Ends a session
      def end_session!(id)
        now = Time.now.utc.iso8601
        @db[:sessions].where(id: id).update(
          status: "ended",
          ended_at: now,
          owner_pid: nil,
          updated_at: now
        )
      end

      # Reaps orphaned sessions: any row still "active" whose owning process is
      # gone is stamped "ended" (#11). This covers the un-trappable hard kill
      # (SIGKILL) and a closed terminal whose SIGHUP never reached the process,
      # where neither the clean-exit path nor the signal traps ran. Rows owned
      # by a live process (including the current one) and rows with no recorded
      # pid (pre-#11 / future sources) are left untouched. Called lazily before
      # listing/resuming sessions; best-effort, returns the number reaped.
      def reap_orphaned_active!
        reaped = 0
        @db[:sessions]
          .where(status: "active")
          .exclude(owner_pid: nil)
          .select(:id, :owner_pid)
          .each do |row|
            next if process_alive?(row[:owner_pid])

            end_session!(row[:id])
            reaped += 1
          end
        reaped
      rescue StandardError
        reaped
      end

      # Returns the most recent active session, if any
      def latest_active
        @db[:sessions]
          .where(status: "active")
          .order(Sequel.desc(:updated_at), Sequel.desc(Sequel.lit("rowid")))
          .first
      end

      # Returns the most recent session worth resuming on a bare `chat`: the
      # last session that actually has messages, regardless of status, so a
      # closed terminal (status still "active") OR a cleanly ended session can
      # both be continued. Empty 0-message sessions are skipped so a stray
      # earlier launch never shadows the real conversation (#99). Returns nil on
      # a true first run, which the CLI uses to fall back to the welcome panel.
      def latest_resumable
        @db[:sessions]
          .where { message_count > 0 }
          .order(Sequel.desc(:updated_at), Sequel.desc(Sequel.lit("rowid")))
          .first
      end

      # Bare `chat` / `--continue` auto-resume target, SCOPED to the launch dir
      # (r5 MF-4 / C-1): the latest resumable session whose stored cwd matches the
      # current directory, never the globally-latest. This is what kills
      # "folder B silently resumes folder A": a session started in /api carries
      # cwd=/api and is invisible to a `chat` launched in /web, which instead
      # finds /web's own latest (or nil ⇒ fresh) — mirroring Claude Code/Codex's
      # per-cwd picker. Two sessions stamped to DIFFERENT dirs can never resolve
      # to each other, so concurrent instances in different folders don't stomp.
      #
      # Also excludes sessions a DIFFERENT live process currently owns
      # (status="active" + an alive owner_pid that isn't us): a second tab in the
      # SAME dir must not silently latch onto the session the first tab is still
      # writing (the two-tabs-stomp-one-session bleed). It forks a fresh session
      # instead; the user can still reattach explicitly with `--resume <id>`.
      # Compares on canonical (realpath) paths so a symlinked launch dir matches
      # the stored root. Returns nil ⇒ caller starts fresh.
      def latest_resumable_for_cwd(cwd = default_cwd)
        target = canonical(cwd)
        return nil if target.nil?

        @db[:sessions]
          .where { message_count > 0 }
          .exclude(cwd: nil)
          .order(Sequel.desc(:updated_at), Sequel.desc(Sequel.lit("rowid")))
          .all
          .find do |row|
            next false unless canonical(row[:cwd]) == target

            # Skip a session another live process is actively writing.
            !live_owned_by_other?(row)
          end
      end

      # A first prompt shorter than this is junk for titling purposes (#128): a
      # throwaway "y"/"ok" the user immediately interrupted would otherwise
      # become the session title and a useless one-char `--resume "y"` matcher.
      TITLE_MIN_CHARS = 3

      # Derives a short, human-readable session title from the first user
      # message. Deterministic and model-free (#103): collapse whitespace, strip
      # a leading slash-command word, take the first line, and truncate on a word
      # boundary. Returns nil for empty/blank input — and for junk-short input
      # (#128) — so the caller leaves the session untitled; the next MEANINGFUL
      # prompt titles it instead (Lifecycle#maybe_set_title retries every turn
      # until a title sticks), and the resume hint falls back to the session id.
      def self.derive_title(text, max: 60)
        cleaned = text.to_s.split("\n").first.to_s.strip.gsub(/\s+/, " ")
        cleaned = cleaned.sub(%r{\A/\S+\s*}, "") # drop a leading slash command
        return nil if cleaned.length < TITLE_MIN_CHARS
        return cleaned if cleaned.length <= max

        truncated = cleaned[0, max].sub(/\s+\S*\z/, "")
        truncated = cleaned[0, max] if truncated.empty?
        "#{truncated}…"
      end

      # Deletes a session and all related records
      def destroy!(id)
        @db.transaction do
          @db[:events].where(session_id: id).delete
          @db[:tool_calls].where(session_id: id).delete
          @db[:messages].where(session_id: id).delete
          @db[:session_summaries].where(session_id: id).delete
          @db[:runs].where(session_id: id).delete
          @db[:sessions].where(id: id).delete
        end
      end

      private

      # The full first user message of a session — what derive_title truncated
      # the title from — so resume-by-title can match the whole prompt (#70).
      def first_user_message(session_id)
        @db[:messages]
          .where(session_id: session_id, role: "user")
          .order(:created_at, Sequel.lit("rowid"))
          .get(:content)
      end

      # True when a process with this pid is currently alive and signalable by
      # us. Process.kill(0, pid) is the canonical liveness probe: it sends no
      # signal but raises Errno::ESRCH when the pid is gone. Errno::EPERM means
      # the pid exists but is owned by another user — still alive, do not reap.
      def process_alive?(pid)
        return false if pid.nil?

        Process.kill(0, pid)
        true
      rescue Errno::ESRCH
        false
      rescue Errno::EPERM
        true
      rescue StandardError
        true # unknown error: be conservative and keep the session
      end

      def generate_id
        SecureRandom.uuid
      end

      # The directory to stamp a new session with: the workspace primary root
      # (terminal.cwd when set, else the process cwd) — the same value the
      # sandbox, @-picker and shell agree is "the" root. Defensive fallback to
      # Dir.pwd if Workspace isn't loaded (e.g. a bare repo spec).
      def default_cwd
        if defined?(Rubino::Workspace)
          Rubino::Workspace.primary_root
        else
          Dir.pwd
        end
      end

      # Canonical (realpath, symlinks resolved) form of a path, so a session's
      # stored cwd and the launch dir compare equal even through symlinks. Falls
      # back to an expanded path when the dir no longer exists on disk, and to
      # nil for blank input.
      def canonical(path)
        return nil if path.nil? || path.to_s.empty?

        File.realpath(path.to_s)
      rescue StandardError
        File.expand_path(path.to_s)
      end

      # True when this session row is currently owned by a DIFFERENT live process
      # (status="active", a recorded owner_pid that is alive and isn't us). Such a
      # session is being actively written by another tab, so auto-resume must not
      # latch onto it. A dead/zombie owner, no pid, an ended session, or our own
      # pid are all fine to resume.
      def live_owned_by_other?(row)
        pid = row[:owner_pid]
        return false if pid.nil?
        return false if pid == Process.pid
        return false unless row[:status].to_s == "active"

        process_alive?(pid)
      end
    end
  end
end
