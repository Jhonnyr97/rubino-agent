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
    # - #destroy! cascades manually to events, tool_calls, messages,
    #   session_summaries and runs inside a single transaction (no FK cascade
    #   in schema; the runs FK would otherwise block the session delete).
    class Repository
      # Public re-export of the live-owner check (#347): explicit `--resume <id>`
      # (the Runner) needs the SAME stomp guard auto-resume already applies, so a
      # second process resuming a session a first live process is still writing
      # can fork instead of interleaving writes into one malformed transcript.
      # Atomically claims a resumable session for THIS process (#390/residual
      # #376). The explicit-resume guard used to be a check-then-stamp:
      # `owned_by_other_live_process?` read owner_pid, and a LATER `update(id,
      # owner_pid:)` stamped it — a TOCTOU window where two concurrent
      # `--resume <id>` both read the SAME dead owner_pid, both passed the
      # guard, and both stamped+wrote the row, interleaving (user,user …) into
      # one malformed transcript. This collapses the read and the stamp into a
      # single compare-and-swap, mirroring Jobs::Queue#claim!: stamp owner_pid
      # only WHILE the row still carries the owner we saw (nil or the dead pid),
      # so exactly ONE racer's UPDATE matches and the loser sees rowcount 0 and
      # forks. A LIVE foreign owner is rejected up front (returns false) so the
      # second resumer still forks rather than stomping the live writer.
      #
      # Returns true iff THIS process won the claim. `seen_owner_pid` is the
      # owner_pid the caller observed (passed so the CAS targets exactly that
      # value); when nil/ours/dead the claim is attempted, when alive-and-foreign
      # it is refused without touching the row.
      def claim_for_resume!(row) # rubocop:disable Naming/PredicateMethod -- mutating CAS (bang); the boolean reports whether THIS caller won the claim
        return false if live_owned_by_other?(row)

        seen = row[:owner_pid]
        now  = Time.now.utc.iso8601
        # CAS: only stamp if the row STILL carries the owner we saw. `seen` is
        # nil (unowned) or a dead pid; either way a concurrent winner has
        # already changed owner_pid to its own live pid, so this WHERE misses.
        cond = seen.nil? ? { owner_pid: nil } : { owner_pid: seen }
        updated = @db[:sessions]
                  .where(id: row[:id])
                  .where(cond)
                  .update(owner_pid: Process.pid, updated_at: now)
        updated.positive?
      end

      # LIKE-pattern escape char for the SAFE id-prefix match (#333a): `%` and
      # `_` are LIKE wildcards, so an unescaped `find("%")` matched EVERY
      # session. id_prefix_match escapes the metacharacters and declares this as
      # the explicit ESCAPE char so only the trailing `%` we append is a wildcard.
      LIKE_ESCAPE = "\\"

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
          title: scrub_text(title),
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
          title: scrub_text(title),
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
        @db[:sessions].where(id_prefix_match(id)).first
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

        id_matches = @db[:sessions].where(id_prefix_match(query)).all
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

      # Lists sessions with optional filters. +cwd+ scopes the listing to a
      # single launch directory (#334): a bare `sessions list` defaults to the
      # current dir so a multi-folder user only sees THIS project's sessions,
      # mirroring the per-cwd auto-resume picker; pass cwd: nil (the `--all`
      # flag) to list every directory's sessions as before. Compared on
      # canonical (realpath) paths so a symlinked launch dir still matches the
      # stored root, which means the cwd filter runs in Ruby (not SQL) AFTER the
      # status/search predicates — the limit is therefore applied post-filter.
      # Sessions created by the `task` tool's subagent runs are tagged
      # source="subagent" (Agent::Runner session_source). They are internal
      # machinery — "Use the shell tool to run exactly this…" prompt-sessions —
      # not the user's own conversations, so they are EXCLUDED from the
      # user-facing list/picker by default (item 2), the way Claude Code hides
      # its Task subagent sessions. They remain reachable by explicit id via
      # #find / #find_by_id_or_title (which never apply this filter), so a
      # subagent session is still resumable when the id is known.
      def list(limit: 20, status: nil, search: nil, cwd: nil, include_subagents: false)
        dataset = @db[:sessions].order(Sequel.desc(:created_at), Sequel.desc(Sequel.lit("rowid")))
        dataset = dataset.where(status: status) if status
        dataset = dataset.exclude(source: "subagent") unless include_subagents
        dataset = dataset.where(title_substring_match(search)) if search && !search.empty?

        return dataset.limit(limit).all if cwd.nil?

        target = canonical(cwd)
        return dataset.limit(limit).all if target.nil?

        dataset.all.select { |row| canonical(row[:cwd]) == target }.first(limit)
      end

      # Updates a session's attributes
      def update(id, **attrs)
        attrs[:title] = scrub_text(attrs[:title]) if attrs.key?(:title)
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
          .where(resumable_predicate)
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

      # Deletes a session and all related records. Also removes the session's
      # on-disk spill/paste artifacts (#374), which the DB cascade alone left
      # ORPHANED: oversized pastes live under <home>/sessions/<id>/ and full
      # tool-output spills under <home>/tool-results/<call_id>.txt. The
      # tool_calls' call_ids are captured BEFORE their rows are deleted so the
      # matching spill files can be removed; the paste subtree is keyed by the
      # session id directly. File removal runs AFTER the transaction commits so
      # a rolled-back delete never strands the DB rows against deleted files.
      def destroy!(id)
        call_ids = @db[:tool_calls].where(session_id: id).select_map(:id)
        @db.transaction do
          @db[:events].where(session_id: id).delete
          @db[:tool_calls].where(session_id: id).delete
          @db[:messages].where(session_id: id).delete
          @db[:session_summaries].where(session_id: id).delete
          @db[:runs].where(session_id: id).delete
          @db[:sessions].where(id: id).delete
        end
        Util::SpillStore.destroy_session_files(id, call_ids: call_ids)
      end

      private

      # The "worth resuming on a bare `chat`/--continue" predicate shared by
      # #latest_resumable and #latest_resumable_for_cwd (#394).
      #
      # Normally a session needs message_count > 0 — empty 0-message launches are
      # skipped so a stray earlier launch never shadows real work (#99). But a
      # COMPACTION child (source="compaction") is born with a fully-populated
      # transcript (the copied head + summary + tail) that the Compressor syncs
      # into message_count AFTER the copy — so if the process exits in the window
      # between the copy and that sync (or the cached counter ever drifts), the
      # arc would be silently skipped and the just-compacted conversation lost.
      # Compaction children always have real messages, so resume them regardless
      # of the cached counter; the count > 0 floor still guards every other source.
      #
      # Sessions tagged source="subagent" are the `task` tool's internal
      # machinery, never a user-facing conversation (#540). `list`/the picker
      # already exclude them; a bare `chat`/`--continue` must too, or its
      # most-recent lookup can land the user INSIDE a background subagent's
      # transcript — a session `sessions list` won't even show. Exclude them
      # here so resume and list agree: a subagent session is never auto-resumed
      # (it stays reachable only by explicit `--resume <id>`).
      def resumable_predicate
        Sequel.&(
          Sequel.~(source: "subagent"),
          Sequel.|({ source: "compaction" }, Sequel[:message_count] > 0)
        )
      end

      # Builds a SAFE id-prefix LIKE condition (#333a). User-supplied short ids
      # flow straight into `Sequel.like(:id, "#{query}%")`, but `%` and `_` are
      # LIKE wildcards — an unescaped `find("%")` matched EVERY session (and
      # `find("a_c")` treated `_` as "any char"), so a stray/crafted query
      # silently resolved to the wrong (or first-of-all) session. Escape the
      # metacharacters in the user portion and declare an explicit ESCAPE char so
      # only the trailing `%` we append stays a wildcard. `\` escapes itself
      # first so a literal backslash in the input can't smuggle past the escape.
      def id_prefix_match(query)
        # `Sequel.like` in Sequel 5 emits no ESCAPE clause, so the escaped
        # metacharacters below would still be treated as wildcards. Declare the
        # escape character explicitly via a parameterized literal (placeholders,
        # not interpolation, so the value stays bound and injection-safe).
        Sequel.lit("id LIKE ? ESCAPE ?", "#{escape_like(query)}%", LIKE_ESCAPE)
      end

      # SAFE title-substring LIKE condition for `list(search:)` (#498). The old
      # form `Sequel.like(:title, "%#{search}%")` INLINED the raw user string
      # into the SQL text instead of binding it (and left `%`/`_` as wildcards),
      # so a title filter containing an em-dash/apostrophe/quote/control byte
      # could surface a raw `SQLite3::SQLException: unrecognized token`. Mirror
      # id_prefix_match: escape the wildcards and bind the value via placeholders
      # with an explicit ESCAPE char.
      def title_substring_match(search)
        Sequel.lit("title LIKE ? ESCAPE ?", "%#{escape_like(search)}%", LIKE_ESCAPE)
      end

      # Escape the LIKE metacharacters (`%`, `_`, and the escape char itself) in
      # user input so they are matched literally, not as wildcards. `\` escapes
      # itself first so a literal backslash in the input can't smuggle past the
      # escape. Pair with an explicit `ESCAPE ?` clause at the call site.
      def escape_like(query)
        query.to_s
             .gsub(LIKE_ESCAPE, "#{LIKE_ESCAPE}#{LIKE_ESCAPE}")
             .gsub("%", "#{LIKE_ESCAPE}%")
             .gsub("_", "#{LIKE_ESCAPE}_")
      end

      # Strip persist-fatal bytes (NUL et al.) from a session title at the write
      # seam (#498). A title is derived from the conversation, so it can carry a
      # NUL the upstream model/paste emitted; NUL is valid UTF-8 (survives
      # String#scrub) but terminates SQLite's C string mid-literal, raising a
      # raw `unrecognized token`. nil is preserved (an untitled session stays
      # untitled, not "").
      def scrub_text(value)
        value.nil? ? nil : Rubino::Util::Output.scrub_utf8(value)
      end

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
      # (a recorded owner_pid that is alive and isn't us), REGARDLESS of status
      # (#376/residual #347). The owner-guard used to fire only on status="active",
      # but a finished turn leaves status="ended" while the resuming process still
      # claims owner_pid (resume stamps owner_pid without flipping status back to
      # active). Two concurrent explicit `--resume <id>` of that ENDED session then
      # raced unguarded and interleaved writes into one malformed transcript
      # (user,user …). Guarding on a live owner of ANY resumable session — not just
      # active ones — makes the second resumer fork/serialize instead.
      #
      # A cleanly-ended session has owner_pid nil (end_session! clears it), so it
      # stays freely resumable; only a session a DIFFERENT live process is right
      # now writing/holding is guarded. A dead/zombie owner, no pid, or our own
      # pid are all fine to resume.
      def live_owned_by_other?(row)
        pid = row[:owner_pid]
        return false if pid.nil?
        return false if pid == Process.pid

        process_alive?(pid)
      end
    end
  end
end
