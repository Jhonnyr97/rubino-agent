# frozen_string_literal: true

module Rubino
  module Tools
    # Abstract base class for all tools.
    # Each tool must implement: name, description, input_schema, risk_level, call.
    class Base
      # ── Class-level DSL ──────────────────────────────────────────────
      class << self
        # Stores class-level declarations that instance methods read.
        # NOTE: we use `tool_name` (not `name`) to avoid shadowing Ruby's
        # built-in Class#name which Zeitwerk / Rails / inspections rely on.
        def tool_name(value = :not_set)
          return @tool_name || default_tool_name if value == :not_set

          @tool_name = value.to_s.freeze
        end

        def description(value = :not_set)
          return @tool_description if value == :not_set

          @tool_description = value.to_s.freeze
        end
        alias desc description

        def risk_level(value = :not_set)
          return @tool_risk_level || :low if value == :not_set

          @tool_risk_level = value.to_sym
        end

        # Registers a single parameter. Generates JSON Schema automatically.
        # Options: type (string/integer/number/boolean/array/object),
        #          desc/description, required (default true).
        def param(name, type: "string", desc: nil, description: nil, required: true)
          tool_params[name.to_s] = Parameter.new(
            name.to_s, type: type.to_s,
            description: desc || description,
            required: required
          )
        end

        # Registers a raw JSON Schema hash for the tool's parameters, used as-is
        # (deep-duped so a mutable literal can't leak). Prefer `param` for simple
        # schemas; use this for shapes the `param` DSL can't express (nested
        # objects, enums, unions). Tools whose schema depends on runtime state
        # (e.g. ReadTool's conditional compress param) override #input_schema as
        # an instance method instead.
        def params(schema)
          @tool_schema = schema
        end

        def tool_params
          @tool_params ||= {}
        end

        def tool_schema
          @tool_schema
        end

        # Returns a class whose name can be overridden by `name "custom"`.
        def default_tool_name
          raw = name.split("::").last # "ReadTool"
          return raw unless raw.end_with?("Tool")

          raw = raw.sub(/Tool\z/, "")   # "Read"
          # Insert underscore between consecutive uppercase + uppercase+lowercase:
          # "Read" stays "read"; "URLTool" → "url"
          raw.gsub(/([A-Z]+)([A-Z][a-z])/, '\1_\2')
             .gsub(/([a-z\d])([A-Z])/, '\1_\2')
             .downcase
        end

        # Instance of Parameter for schema generation.
        class Parameter
          attr_reader :name, :type, :description, :required

          def initialize(name, type: "string", description: nil, required: true)
            @name = name
            @type = type
            @description = description
            @required = required
          end
        end

        # Builds the JSON Schema from a raw `params` hash or `param` declarations.
        # Returns nil when nothing is declared (tool uses an #input_schema
        # override). Uses symbol keys — ruby_llm stringifies them before sending
        # to the provider, and tests assert against symbol keys.
        def build_input_schema
          return deep_dup(tool_schema) if tool_schema
          return nil if tool_params.empty?

          properties = tool_params.to_h do |_name, param|
            schema = {
              type: map_param_type(param.type),
              description: param.description
            }.compact
            schema[:items] = { type: "string" } if schema[:type] == "array"
            [param.name, schema]
          end

          required = tool_params.values.select(&:required).map(&:name)

          { type: "object", properties: properties, required: required }
        end

        # Recursive deep dup for hashes/arrays/values.
        def deep_dup(value)
          case value
          when Hash  then value.each_with_object({}) { |(k, v), h| h[k] = deep_dup(v) }
          when Array then value.map { |v| deep_dup(v) }
          else value
          end
        end

        def map_param_type(type)
          case type.to_s
          when "integer", "int" then "integer"
          when "number", "float", "double" then "number"
          when "boolean" then "boolean"
          when "array" then "array"
          when "object" then "object"
          else "string"
          end
        end
      end

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

      # Returns the tool name (used in LLM tool definitions).
      # Reads from class-level `tool_name` declaration, falls back to deriving
      # from the class name (ReadTool → "read"). Override with an instance
      # method for full control.
      def name
        self.class.tool_name
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

      # Returns a description for the LLM.
      # Reads from class-level `description` declaration.
      def description
        self.class.description
      end

      # Returns the JSON schema for input parameters.
      # Auto-generates from `param` declarations or `params` block when present.
      # Tools with dynamic schemas (ReadTool's conditional compress param)
      # override this method.
      def input_schema
        self.class.build_input_schema
      end

      # Returns the risk level: :low, :medium, :high.
      # Reads from class-level `risk_level` declaration (default :low).
      def risk_level
        self.class.risk_level
      end

      # True only for tools whose code runs on an external MCP server
      # (MCPToolWrapper overrides this). Built-ins are NEVER MCP — the display
      # layer keys the `(mcp:server)` marker off this predicate, NOT off the
      # tool name's shape, so a built-in with an underscore in its name
      # (read_attachment, shell_output) is never mistaken for `server_tool`.
      def mcp?
        false
      end

      # The label shown in the live tool card / approval card. Built-ins render
      # under their bare name; MCPToolWrapper overrides this to append the
      # `(mcp:server)` source marker. The MODEL-FACING #name is unaffected.
      def display_name
        name
      end

      # Executes the tool with given arguments, returns output string.
      # Normalizes string/symbol keys into keyword arguments and delegates
      # to execute(**kwargs). Every built-in tool now implements execute(),
      # so this method is the single entry point used by ToolExecutor.
      #
      # When a required keyword is missing from the LLM's hash, we inject
      # nil instead of letting Ruby raise ArgumentError — the tool's own
      # nil checks produce a clear error message, and the method dispatch
      # never fails.
      def call(arguments)
        kwargs = normalize_call_args(arguments)
        # Introspect execute's parameter list and pad missing required
        # keywords with nil so the dispatch never raises.
        method(:execute).parameters.each do |type, name|
          next unless type == :keyreq
          kwargs[name] = nil unless kwargs.key?(name)
        end
        execute(**kwargs)
      end

      # Tools implement their logic here, receiving keyword arguments that
      # are already normalized from the LLM's JSON hash.
      def execute(**)
        raise NotImplementedError, "#{self.class}#execute not implemented"
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

      # Class-level access to the write-boundary predicates for a caller that
      # has no tool instance — the ApprovalPolicy's out-of-workspace widen gate.
      # The predicates are STATELESS (they read config / Workspace / ENV / home
      # live on every call, never an ivar), so a memoized throwaway instance is a
      # faithful, allocation-free way to reuse the EXACT logic the tools enforce
      # rather than re-implementing it — the same throwaway-instance idiom
      # Attachments::Classify already uses for #canonical_path. One source of
      # truth for "may this be written / must it be widened", shared by the
      # approval decision and the tool's own guard.
      def self.boundary
        @boundary ||= Class.new(self) { def name = "__boundary__" }.new
      end

      # The directory to ADD to the workspace so a write to +path+ becomes
      # allowed, or nil when no widening applies. Returns nil when the target is
      # ALREADY writable (in-workspace or temp scratch), when strict mode is off
      # (there is no jail to widen), or when the target is under the agent home
      # (a deliberately non-writable trust anchor we must NEVER offer to widen,
      # #290). Otherwise returns the deepest EXISTING ancestor directory of the
      # target: that is the dir Workspace.add can accept (it requires an existing
      # directory) and the minimal grant that lets the write land. Drives the
      # Claude-Code-aligned "write outside the workspace → ask, then add the
      # directory for the session" flow; PUBLIC so Base.boundary can reach it.
      def widen_target_for(path)
        return nil unless workspace_strict?

        expanded = expand_workspace_path(path)
        return nil if writable_workspace?(expanded)
        return nil if under_agent_home?(expanded)

        nearest_existing_dir(expanded)
      end

      protected

      # Normalizes the hash from the LLM (string keys from JSON) into symbol
      # keys, so tools using call(**kwargs) don't need to check both.
      def normalize_call_args(arguments)
        return {} if arguments.nil?
        return arguments.transform_keys(&:to_sym) if arguments.respond_to?(:transform_keys)

        {}
      end

      # Walks up from +expanded+ to the deepest ancestor that exists and is a
      # directory. The target is a not-yet-created file (the common widen case)
      # or an existing file, so the search starts at its parent. nil only if
      # nothing up the chain is a real directory (the filesystem root always is,
      # so this is effectively total).
      def nearest_existing_dir(expanded)
        dir = File.dirname(expanded)
        dir = File.dirname(dir) until File.directory?(dir) || dir == File.dirname(dir)
        File.directory?(dir) ? dir : nil
      end

      # Resolves a model-supplied path to an absolute one, anchoring a RELATIVE
      # path at the SESSION cwd (Workspace.current_cwd) instead of the process
      # cwd.
      #
      # `File.expand_path(rel)` anchors at Dir.pwd, but the agent's "current
      # directory" — the dir the @-picker, shell, sandbox and now every file
      # tool agree on — is Workspace.current_cwd. It DEFAULTS to primary_root
      # (terminal.cwd || launch cwd), which is what bin/dev / the QA harness
      # point at while the process launches from the parent; and it CARRIES a
      # `cd subdir` done in the shell, so a relative `foo.txt` written right
      # after `cd subdir` lands in subdir, not the workspace root (#544/#545).
      # An ABSOLUTE path (or a ~ path) passes straight through unchanged, so the
      # workspace guard downstream still sees the real target.
      def expand_workspace_path(path)
        str = path.to_s
        return File.expand_path(str) if str.start_with?(File::SEPARATOR, "~")

        File.expand_path(str, Workspace.current_cwd)
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

      # The WRITE/EDIT sandbox check: within the workspace OR under the temp
      # scratch set ($TMPDIR + /tmp). The OS write-jail already grants scratch as
      # writable and `shell` can freely write there, but the structured write/edit
      # guard refused it — so `write /tmp/x` failed while `shell printf > /tmp/x`
      # worked, an inconsistency the model tripped on (#77a). This is deliberately
      # SEPARATE from #within_workspace? so the relaxation applies ONLY to writes:
      # the AUX-LLM read guard (#outside_workspace?, which exfiltrates bytes to a
      # third-party model) stays strict and never reaches scratch.
      def writable_workspace?(expanded)
        return true unless workspace_strict?
        return true if within_workspace?(expanded)

        target_real = canonical_path(expanded)
        return false unless target_real

        temp_scratch?(target_real)
      end

      # The shared temp scratch roots ($TMPDIR + /tmp), resolved through symlinks
      # so the comparison matches canonical_path's output.
      def temp_scratch_roots
        [ENV.fetch("TMPDIR", nil), "/tmp"].filter_map do |p|
          next if p.nil? || p.empty? || !File.directory?(p)

          File.realpath(File.expand_path(p))
        rescue StandardError
          nil
        end.uniq
      end

      def temp_scratch?(target_real)
        # The agent home (~/.rubino) holds the sandbox's own trust anchors and is
        # DELIBERATELY non-writable from the jail (see Security::Sandbox); a temp
        # home in tests sits under $TMPDIR, so carve it out here too — scratch
        # must never become a self-tamper write path.
        return false if under_agent_home?(target_real)

        temp_scratch_roots.any? do |root|
          target_real == root || target_real.start_with?("#{root}#{File::SEPARATOR}")
        end
      end

      # Resolves `path` through every symlink to its canonical destination.
      # When the path doesn't exist yet (create-new-file flow) walks up to
      # the deepest existing ancestor, realpaths that, then re-joins the
      # missing tail. The tail itself can't traverse — expand_path already
      # collapsed `..` segments before we got here.
      def canonical_path(path, symlink_hops = 0)
        return nil if path.nil? || path.to_s.empty?

        expanded = File.expand_path(path.to_s)
        return File.realpath(expanded) if File.exist?(expanded)

        # A DANGLING symlink (the link exists; its target does not yet) reports
        # File.exist? == false because exist? follows the link to the missing
        # target — so the create-new-file fallback below would canonicalize the
        # LINK'S OWN location and wrongly accept it as in-workspace, even though
        # a write through the link lands at the target OUTSIDE the workspace.
        # Resolve where the link actually points (recursively, in case the
        # target is itself a dangling link) so the sandbox confines the real
        # write destination, not the harmless-looking link path. The hop counter
        # bails a symlink cycle (a→b→a) — exist? never trips on a cycle, so an
        # unbounded recurse would loop; matching realpath's ELOOP, return nil.
        if File.symlink?(expanded)
          return nil if symlink_hops >= 40

          target = File.expand_path(File.readlink(expanded), File.dirname(expanded))
          return canonical_path(target, symlink_hops + 1)
        end

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
      # tools (vision) ONLY. Those route the raw file bytes
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

      # True when +expanded+ resolves under the Rubino home directory. Symlinks
      # are resolved on both sides so a link can't be used to claim home-ness.
      def under_agent_home?(expanded)
        home = Rubino.home_path
        return false if home.nil? || home.to_s.empty?

        home_real   = (File.realpath(home) if File.exist?(home)) || File.expand_path(home)
        target_real = canonical_path(expanded)
        return false unless target_real

        target_real == home_real || target_real.start_with?("#{home_real}#{File::SEPARATOR}")
      rescue StandardError => e
        # Fail closed (treat as NOT under home) on any resolution error — but log
        # it: this predicate gates a security-relevant decision, so a swallowed
        # error that mis-resolves home-ness must at least leave a trace.
        Rubino.logger&.warn(event: "tools.under_agent_home_failed",
                            error: e.message, error_class: e.class.name)
        false
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
