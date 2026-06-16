# frozen_string_literal: true

module Rubino
  module Tools
    # Abstract base class for all tools.
    # Each tool must implement: name, description, input_schema, risk_level, call.
    class Base
      # Set by ToolExecutor before each call so long-running tools (shell,
      # http, watchers) can poll for user cancellation. Default is nil — the
      # tool should treat that as "no cancellation possible" and not crash.
      attr_accessor :cancel_token

      # Session-scoped ReadTracker injected by ToolExecutor. ReadTool
      # registers successful reads; EditTool / MultiEditTool consult it
      # before writing so they can refuse to edit a file the model never
      # opened in this session. Nil-tolerant: tools that don't care just
      # ignore it.
      attr_accessor :read_tracker

      # Optional Proc, injected by ToolExecutor, that the tool can call with
      # incremental output chunks during a long-running call. ShellTool uses
      # this to stream stdout/stderr lines as the subprocess writes them
      # instead of dumping everything at end-of-command. Nil-tolerant: a
      # tool with no streamable output (read, edit, glob) just ignores it.
      attr_accessor :stream_chunk

      # Optional render hint the ToolExecutor forwards to the UI alongside each
      # streamed chunk (and the end-of-call body). :diff makes the CLI colorize
      # +/-/@@ lines AND show the full hunks instead of collapsing to the 3-line
      # preview — so "show me the diff" surfaces the real diff, not a snippet.
      # Default nil ⇒ :plain. Set it from #call once the command/content kind is
      # known; the streaming lambda reads it live.
      attr_accessor :stream_kind

      # Convenience guard so tools don't sprinkle nil-checks at every emit.
      def emit_chunk(text)
        return if text.nil? || text.to_s.empty?

        @stream_chunk&.call(text.to_s)
      end

      # True when the user has requested cancellation. Cheap, lock-protected.
      # Use in tight loops; on true, terminate gracefully and either return
      # an "interrupted" string or raise Rubino::Interrupted.
      def cancellation_requested?
        @cancel_token&.cancelled?
      end

      # Returns the tool name (used in LLM tool definitions)
      def name
        raise NotImplementedError, "#{self.class}#name not implemented"
      end

      # The `tools.<key>` config gate that enables/disables this tool. Single
      # source of truth shared with Registry#tool_enabled_in_config? and the
      # `tools` CLI command, so the displayed state always matches the state
      # the registry actually enforces. Defaults to the tool's own name;
      # tools whose config key differs (webfetch/websearch both gate on
      # `tools.web`) override this. Returning a key absent from config means
      # the tool is enabled (opt-out model).
      def config_key
        name
      end

      # Returns a description for the LLM
      def description
        raise NotImplementedError, "#{self.class}#description not implemented"
      end

      # Returns the JSON schema for input parameters
      def input_schema
        raise NotImplementedError, "#{self.class}#input_schema not implemented"
      end

      # Returns the risk level: :low, :medium, :high
      def risk_level
        :low
      end

      # Executes the tool with given arguments, returns output string
      def call(arguments)
        raise NotImplementedError, "#{self.class}#call not implemented"
      end

      # Returns true if this tool requires user confirmation
      def risky?
        %i[medium high].include?(risk_level)
      end

      # Returns the tool definition for LLM registration
      def to_tool_definition
        {
          name: name,
          description: description,
          parameters: input_schema
        }
      end

      protected

      # Resolves a model-supplied path to an absolute one, anchoring a RELATIVE
      # path at the workspace primary root (terminal.cwd || launch cwd) instead
      # of the process cwd.
      #
      # `File.expand_path(rel)` anchors at Dir.pwd, but the agent's "current
      # directory" — the dir the @-picker, shell/test and sandbox all agree on
      # — is Workspace.primary_root, which is terminal.cwd when configured (e.g.
      # bin/dev / the QA harness point it at a workspace subdir while the process
      # launches from the parent). When the two diverge, a relative `shopkit/
      # cart.py` resolved one directory too shallow and 404'd, forcing an
      # ls→glob→re-read detour (r6 F3). Anchoring at primary_root fixes that
      # while an ABSOLUTE path (or a ~ path) passes straight through unchanged,
      # so the workspace guard downstream still sees the real target.
      def expand_workspace_path(path)
        str = path.to_s
        return File.expand_path(str) if str.start_with?(File::SEPARATOR, "~")

        File.expand_path(str, workspace_root)
      end

      # Filesystem sandbox for write/edit/delete operations.
      #
      # Defaults to Dir.pwd, overridable via terminal.cwd in config. Mutating
      # tools must call within_workspace? before touching the disk so a prompt
      # injection that asks for `file_path: "/etc/passwd"` is refused at the
      # tool boundary, before the approval prompt even sees the path.
      #
      # The check resolves every symlink with File.realpath before comparing
      # against the workspace root: dropping a `link → /etc` inside the
      # workspace and writing through it used to bypass the boundary because
      # expand_path alone never crosses the symlink. realpath walks the
      # filesystem and gives us the canonical destination, so an in-workspace
      # path that ultimately points outside is rejected like any other escape.
      # For non-existent targets (write-creates-new-file) we resolve the
      # deepest existing ancestor and re-attach the remainder — the new file
      # will land at that ancestor, so the ancestor is what we sandbox.
      #
      # Set tools.workspace_strict=false in config.yml to disable globally
      # (the agent then trusts the model + the approval flow alone).
      # The directory tools sandbox to. Exposed as a class method so the
      # File API operations can root their Workspace at the SAME place
      # (otherwise produced artifacts under this root look like traversal
      # escapes relative to paths_home and the download 422s).
      # The PRIMARY root — terminal.cwd or the launch cwd. Kept as the single
      # source of truth for "the" directory: the @-picker, shell/test cwd, the
      # File API workspace and the attachment downloader all root here so they
      # agree. The write/edit SANDBOX, however, spans every root (see
      # #within_workspace?) so an added dir is also writable.
      def self.workspace_root
        Workspace.primary_root
      end

      # Every allowed root (primary + any --add-dir / /add-dir dirs). The
      # sandbox accepts a target under ANY of these.
      def self.workspace_roots
        Workspace.roots
      end

      def workspace_root
        self.class.workspace_root
      end

      def workspace_roots
        self.class.workspace_roots
      end

      def workspace_strict?
        Rubino.configuration.dig("tools", "workspace_strict") != false
      end

      # True when +expanded+ resolves under ANY allowed root. Generalised from
      # the old single-root check so a write/edit/multi_edit under a dir added
      # via --add-dir / /add-dir is accepted, while a path outside every root
      # is still refused. Symlinks are resolved (canonical_path) before the
      # comparison so an in-workspace symlink to /etc can't escape.
      def within_workspace?(expanded)
        return true unless workspace_strict?

        target_real = canonical_path(expanded)
        return false unless target_real

        Workspace.canonical_roots.any? do |root_real|
          target_real == root_real ||
            target_real.start_with?("#{root_real}#{File::SEPARATOR}")
        end
      end

      # Resolves `path` through every symlink to its canonical destination.
      # When the path doesn't exist yet (create-new-file flow) walks up to
      # the deepest existing ancestor, realpaths that, then re-joins the
      # missing tail. The tail itself can't traverse — expand_path already
      # collapsed `..` segments before we got here.
      def canonical_path(path)
        return nil if path.nil? || path.to_s.empty?

        expanded = File.expand_path(path.to_s)
        return File.realpath(expanded) if File.exist?(expanded)

        ancestor = expanded
        tail     = []
        until File.exist?(ancestor)
          parent = File.dirname(ancestor)
          break if parent == ancestor

          tail.unshift(File.basename(ancestor))
          ancestor = parent
        end
        return nil unless File.exist?(ancestor)

        File.join(File.realpath(ancestor), *tail)
      rescue Errno::ENOENT, Errno::EACCES, Errno::ELOOP
        nil
      end

      def workspace_violation_message(path)
        roots = workspace_roots
        where = roots.length == 1 ? roots.first : "any allowed root (#{roots.join(", ")})"
        "Error: refusing to access '#{path}' — outside #{where}. " \
          "Set tools.workspace_strict=false in config.yml to disable this check."
      end

      # Typed "outside workspace" error gate, retained for the AUX-LLM read
      # tools (summarize_file, vision) ONLY. Those route the raw file bytes
      # through a third-party auxiliary model, so an out-of-workspace read would
      # EXFILTRATE a sibling-repo secret / ~/.ssh file — a stronger threat than
      # the in-process read/grep/glob, which were relaxed to broad in #406. A
      # `path` is outside iff within_workspace? is false (strict mode on) and it
      # isn't under the agent home; strict mode off never fires.
      def outside_workspace?(expanded)
        return false unless workspace_strict?
        return false if within_workspace?(expanded)
        # The agent's OWN home dir (~/.rubino) holds pastes, attachments and
        # session files the agent explicitly points the model at — legitimate
        # reads even though they sit outside the project workspace.
        return false if under_agent_home?(expanded)

        true
      end

      def outside_workspace_message(path)
        roots = workspace_roots
        roots_list = roots.length == 1 ? roots.first : roots.join(", ")
        { output: "Error: '#{path}' is outside your workspace roots (#{roots_list}) — " \
                  "it is NOT missing, you are not allowed to access it here. " \
                  "Run `/add-dir #{File.dirname(File.expand_path(path.to_s))}` to include its folder, " \
                  "or relaunch in that directory. Do not try to create or overwrite it.",
          error_code: :outside_workspace }
      end

      # UNIFIED SECRET-PATH PREDICATE (#446). One "is this a secret/credential
      # path?" question used by BOTH the read side (read/grep/glob) and the
      # write side (write/edit/multi_edit/apply_patch). Previously the read
      # denylist (#406) was a NARROW subset (.env*/.envrc + agent-home) and the
      # write denylist (#413) the SUPERSET; the maintainer decision is that
      # reading OR writing a secret both require EXPLICIT user approval, applied
      # to the SAME set. So there is now ONE set — the (wider) write set — and
      # ONE predicate: #secret_path_category. The approval gate lives in
      # Security::ApprovalPolicy#decide (returns :ask for a secret target), which
      # gives us the existing flow for free: interactive → approval dropdown
      # auto-opens; approved → the tool proceeds; denied → refused; headless (no
      # human) → fails CLOSED via ToolExecutor's :noninteractive floor. The tools
      # therefore NO LONGER self-refuse a secret in #call — an approved read of
      # your .env must actually return its bytes, and an approved write must
      # actually write. The predicate is still consulted directly in ONE place:
      # GrepTool post-filters its RESULTS through it so an include-glob
      # (`include: "*.env"`) over a directory can't leak a secret the per-target
      # gate never saw (F2).
      #
      # DELIBERATE DIVERGENCE FROM HERMES: Hermes' file_safety.get_read_block_error
      # FLAT-DENIES reading project .env* (model-facing deny, no human in the
      # loop, defense-in-depth only). rubino instead routes the read through an
      # explicit user APPROVAL gate (ask, not deny) so the agent CAN read/update
      # your .env when you say yes — stricter than Claude Code's default
      # (ungated reads) and aider, more content-aware than Codex's OS-sandbox.
      #
      # Matches (by BASENAME, in any directory):
      #   - project credential files: .env, .env.* (.env.local/.production), .envrc
      #   - shell/credential dotfiles: .netrc, .pgpass, .npmrc, .pypirc,
      #     .git-credentials, .bashrc, .zshrc, .profile, .bash_profile, .zprofile
      # Matches (by absolute PATH / PREFIX):
      #   - ~/.ssh, ~/.aws, ~/.gnupg, ~/.kube, ~/.docker, ~/.azure,
      #     ~/.config/gh, ~/.config/gcloud  (the whole tree)
      #   - /etc/sudoers, /etc/sudoers.d/*, /etc/passwd, /etc/shadow, /etc/systemd/*
      #   - anything UNDER the agent home (~/.rubino) that holds auth/secrets:
      #     the home .env, the sqlite DB, any *oauth* file, an mcp-tokens/ dir,
      #     and *.key / *.pem material.
      # Returns the matched category string (truthy) or nil when the path is not
      # a secret. (Non-predicate: the truthy return carries the category string
      # the approval question / block message interpolates.)
      #
      # The UNIFIED predicate (delegates to the single source of truth,
      # Security::SecretPath.category). Returns the matched-secret category
      # string (truthy) for a secret/credential path, or nil for a normal file.
      def secret_path_category(expanded)
        Security::SecretPath.category(expanded)
      end

      # Denial body for a secret hit that the GrepTool post-filter strips out of
      # an include-glob result set (F2): the directory grep wasn't itself a
      # secret target, so the per-call approval gate never saw it — we refuse the
      # leaking RESULTS here instead. error_code stays :secret_denied for parity
      # with the read side.
      def secret_filtered_block_message(path, category)
        { output: "Error: refusing to return secret content from '#{path}' — it is a #{category}. " \
                  "The search matched a credential file via an include-glob; secrets are not " \
                  "returned without explicit user approval. Ask the user, or read the file " \
                  "directly (which prompts for approval).",
          error_code: :secret_denied }
      end

      # True when +expanded+ resolves under the Rubino home directory. Symlinks
      # are resolved on both sides so a link can't be used to claim home-ness.
      def under_agent_home?(expanded)
        home = Rubino.home_path
        return false if home.nil? || home.to_s.empty?

        home_real   = (File.realpath(home) if File.exist?(home)) || File.expand_path(home)
        target_real = canonical_path(expanded)
        return false unless target_real

        target_real == home_real || target_real.start_with?("#{home_real}#{File::SEPARATOR}")
      rescue StandardError
        false
      end

      # Reads a file and scrubs a stray non-UTF-8 byte (e.g. a Latin-1 `é` in a
      # legacy/EU source) to the replacement char. Shared by EditTool and
      # MultiEditTool so a single bad byte doesn't raise "invalid byte sequence
      # in UTF-8" out of the include?/scan/sub that follow and leave the file
      # uneditable. Lossy on the offending byte, graceful for everything else.
      #
      # IMPORTANT (#326): this is for MODEL CONTEXT only — NEVER feed the
      # scrubbed buffer to a File.write, because `scrub` rewrites every
      # non-UTF-8 byte on UNTOUCHED lines to U+FFFD, so a one-line ASCII edit
      # would lossily corrupt the whole file. Use #read_for_edit for the
      # read-modify-write path.
      def read_scrubbed(path)
        content = File.read(path)
        content.valid_encoding? ? content : content.scrub
      end

      # Reads a file for the edit/multi_edit READ-MODIFY-WRITE path (#326).
      #
      # Returns the raw bytes as BINARY (ASCII-8BIT) so the literal
      # include?/scan/sub/gsub run byte-wise and every byte OUTSIDE the matched
      # span is preserved exactly — a Latin-1 `André` on an untouched line is
      # written back byte-identical even when the file isn't valid UTF-8. The
      # model-supplied old_string/new_string are likewise compared/spliced as
      # bytes (see #to_match_bytes), so a UTF-8 needle still matches its UTF-8
      # bytes in the file. Valid-UTF-8 files behave exactly as before.
      def read_for_edit(path)
        File.binread(path)
      end

      # Forces a model-supplied string to the SAME binary encoding the on-disk
      # content carries in #read_for_edit, so include?/scan/sub compare raw
      # bytes (a UTF-8 `é` needle matches its two on-disk bytes). dup so we
      # never mutate the caller's frozen literal.
      def to_match_bytes(str)
        str.to_s.dup.force_encoding(Encoding::BINARY)
      end

      # Read-before-edit gate shared by EditTool and MultiEditTool. Refuses the
      # write when the model never read this file in the current session, or
      # read it but the file changed on disk since. Returns nil (proceed) or an
      # error Hash carrying error_code: :stale_read for the model to recover
      # from. No tracker injected → no gate (single-tool unit tests, MCP calls).
      #
      # `verb` is the only token that varies between callers ("edit" /
      # "edits"); the wording is otherwise identical, so it lives here.
      def read_gate_error(expanded, display_path, verb:)
        return nil unless @read_tracker

        unless @read_tracker.seen?(expanded)
          return { output: "Error: must use the read tool on #{display_path} in this session before editing it. " \
                           "Read it first so the #{verb} can verify the surrounding context.",
                   error_code: :stale_read }
        end

        # Fresh? matches on EITHER unchanged mtime OR unchanged content hash, so
        # the agent's own write (refreshed via note_write), a no-op touch, a
        # CRLF normalisation, or a linter rewrite to identical bytes does NOT
        # trip this guard (r5 B2). Only a genuine content change does.
        return nil if @read_tracker.fresh?(expanded)

        stashed = @read_tracker.mtime_at_read(expanded)
        current = File.mtime(expanded)
        { output: "Error: #{display_path} changed on disk since the last read " \
                  "(read at #{stashed&.utc&.iso8601}, now #{current.utc.iso8601}). " \
                  "Re-read the file before editing so the #{verb} reflect the current contents.",
          error_code: :stale_read }
      end

      # Read-before-overwrite gate for WriteTool on an EXISTING file (r5 MF-2).
      # Refuses a blind `write` that would clobber a file the model never read
      # this session (or read but is now stale on disk). New files don't reach
      # here. Returns nil (proceed) or an error Hash with error_code:
      # :unread_overwrite. No tracker → no gate.
      def overwrite_guard_error(expanded, display_path)
        return nil unless @read_tracker

        unless @read_tracker.seen?(expanded)
          return { output: "Error: refusing to overwrite existing file #{display_path} — " \
                           "you have not read it this session, so a blind write would clobber its " \
                           "current contents. Read it first (then use `edit`/`multi_edit` for a " \
                           "targeted change, or `write` the full intended content).",
                   error_code: :unread_overwrite }
        end

        return nil if @read_tracker.fresh?(expanded)

        { output: "Error: #{display_path} changed on disk since you last read it — " \
                  "re-read it before overwriting so you don't clobber newer content.",
          error_code: :unread_overwrite }
      end
    end
  end
end
