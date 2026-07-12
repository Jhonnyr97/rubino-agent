# frozen_string_literal: true

require "ruby_llm"

module Rubino
  module Tools
    # Abstract base class for all tools. Inherits from RubyLLM::Tool for
    # ecosystem compatibility (param DSL, schema generation, name derivation)
    # and layers rubino-specific features on top: risk levels, workspace
    # sandbox, cancellation, streaming, read-tracker gates, and MCP detection.
    class Base < RubyLLM::Tool
      # ── Rubino class-level: Security + Presentation ──

      class << self
        # Declares the Security subclass for this tool.
        #   security EditSecurity
        #
        # NOTE: @tool_security is a class-instance variable — it does NOT
        # inherit. Subclassing a concrete tool (class Foo < EditTool) silently
        # loses the declaration and will raise "must declare `security …`".
        # Either re-declare in the subclass or avoid tool-to-tool inheritance.
        def security(klass)
          @tool_security = klass.new
        end

        # Declares the Presentation subclass for this tool.
        #   presentation EditPresentation
        #
        # Same inheritance caveat as security above.
        def presentation(klass)
          @tool_presentation = klass.new
        end

        def tool_security
          if @rubino_risk_level && !static_low_risk?
            @tool_security ||= synthesize_security
          else
            @tool_security || ToolSecurity.new
          end
        end

        def tool_presentation
          @tool_presentation || ToolPresentationCLI.new
        end

        # Declares the redaction profile for this tool's output.
        #   redaction_profile :code       # source file — skip ENV/JSON patterns
        #   redaction_profile :none       # structured output — no redaction
        #
        # Default is :shell (full patterns — fail-safe). Tools opt DOWN
        # to :none, never UP toward less security.
        def redaction_profile(profile = nil)
          if profile
            @redaction_profile = profile
          else
            @redaction_profile || :shell
          end
        end

        # Opts this tool into the multiplexer dropdown WHILE IT RUNS. The
        # lambda receives the tool's arguments hash and returns a header
        # string displayed as the dropdown-row label. Omit for fast/quiet
        # tools — the default is NOT to appear in the dropdown (opt-in).
        #
        #   live_card ->(args) { "🔨 build #{args[:target]}" }
        #
        #   after: 1.second  — defer the card until the tool has run for at
        #     least this long. Output is buffered silently; if the tool finishes
        #     before the threshold the card is never shown and output is delivered
        #     atomically. If the tool exceeds the threshold the card appears in
        #     the picker — enter it with ⏎ to see the live output.
        #
        # An inline tool BLOCKS the agent thread (it is synchronous), so the
        # card is the live window on that blocking operation — the user can
        # watch its streaming output via ⏎ (enter the card),
        # exactly like a background shell or subagent.
        def live_card(header_lambda = nil, after: nil)
          if header_lambda
            @live_card_header = header_lambda
            @live_card_after  = after
          else
            @live_card_header
          end
        end

        # True when this tool declared +live_card+ — the executor uses this
        # to decide whether to register an InlineToolAdapter before running
        # the tool.
        def live_card?
          !@live_card_header.nil?
        end

        # The header lambda declared via +live_card+, or nil. The executor
        # calls it with the tool's arguments to build the dropdown label.
        attr_reader :live_card_header

        # Defer threshold (in seconds, Float) declared via +live_card after: …+,
        # or nil when the card appears immediately. Read by InlineToolAdapter to
        # gate card visibility and streaming output.
        attr_reader :live_card_after

        # ── Risk macro ──
        #
        #   risk :high                                     # static
        #   risk :high, allow_widening: true
        #   risk do |tool|                                 # dynamic per-call
        #     tool.read_tracker&.accessed?("secrets.yml") ? :high : :medium
        #   end
        #
        # The full `security SomeClass` escape hatch still works for tools
        # that need custom sandbox/read-gate behaviour beyond what risk() covers.
        def risk(level = nil, sandbox: nil, require_read: nil, allow_widening: nil, &block)
          @rubino_risk_level     = block || level
          @rubino_sandbox        = sandbox if sandbox
          @rubino_require_read   = require_read unless require_read.nil?
          @rubino_allow_widening = allow_widening unless allow_widening.nil?
        end

        # ── Live card macro ──
        #
        #   live "💻 %s", :command                       # simple template
        #   live "📤 exporting %s", :format, after: 1
        #   live do |args|                                 # complex header
        #     "#{args[:command].truncate(40)} (#{args[:cwd]})"
        #   end
        #
        # Sugar over +live_card+: builds a sprintf-style header lambda
        # from a template and param names, or uses the given block directly.
        def live(template = nil, *param_names, after: nil, &block)
          header = if block
                     block
                   elsif template
                     ->(args) { template % param_names.map { |n| args[n] } }
                   else
                     raise ArgumentError, "live requires a template string or a block"
                   end
          live_card(header, after: after)
        end

        private

        def static_low_risk?
          @rubino_risk_level == :low
        end

        def synthesize_security
          level_or_lambda = @rubino_risk_level
          sandbox_override     = @rubino_sandbox
          require_read_val     = @rubino_require_read
          allow_widening_val   = @rubino_allow_widening

          Class.new(ToolSecurity) do
            if level_or_lambda.respond_to?(:call)
              # Dynamic: lambda receives the tool instance at call time
              define_method(:dynamic_risk?) { true }
              define_method(:risk_for) { |tool| level_or_lambda.call(tool) }
            else
              define_method(:risk) { level_or_lambda }
            end
            define_method(:risky?) { %i[medium high].include?(risk) } unless level_or_lambda.respond_to?(:call)
            define_method(:sandbox) { sandbox_override } if sandbox_override
            define_method(:require_read) { require_read_val } unless require_read_val.nil?
            define_method(:allow_widening) { allow_widening_val } unless allow_widening_val.nil?
          end.new
        end
      end

      # ── Rubino runtime: injected by ToolExecutor before each call ──

      # Cancellation token polled by long-running tools (shell, http, watchers).
      # Nil-tolerant: tools treat nil as "no cancellation possible".
      attr_accessor :cancel_token

      # Session-scoped ReadTracker. ReadTool registers reads; EditTool /
      # MultiEditTool consult it before writing. Nil-tolerant.
      attr_accessor :read_tracker

      # Optional Proc for incremental output chunks during long calls.
      attr_accessor :stream_chunk

      # Render hint forwarded to the UI alongside streamed chunks.
      # :diff makes the CLI colorize +/-/@@ lines. Default nil ⇒ :plain.
      attr_accessor :stream_kind

      # ── Rubino instance methods (layered on top of RubyLLM::Tool) ──

      # Override ruby_llm's name derivation: strip the Rubino::Tools::
      # module prefix so that e.g. EditTool → "edit", not
      # "rubino--tools--edit".
      def name
        klass_name = self.class.name.split("::").last
        normalized = klass_name.to_s.dup.force_encoding("UTF-8").unicode_normalize(:nfkd)
        normalized.encode("ASCII", replace: "")
                  .gsub(/[^a-zA-Z0-9_-]/, "-")
                  .gsub(/([A-Z]+)([A-Z][a-z])/, '\1_\2')
                  .gsub(/([a-z\d])([A-Z])/, '\1_\2')
                  .downcase
                  .delete_suffix("_tool")
      end

      # The `tools.<key>` config gate. Defaults to the tool's own name.
      # Override for tools that share a config key (webfetch/websearch → "web").
      def config_key
        name
      end

      # Bridge from rubino's `input_schema` to ruby_llm's `params_schema`.
      # ruby_llm stringifies all keys (provider-ready JSON), but rubino
      # tests and tool code access the schema with symbol keys. Symbolize
      # them here so existing callers don't break.
      # Tools with dynamic schemas (ReadTool's conditional compress param)
      # override this instance method.
      def input_schema
        schema = params_schema
        return nil unless schema

        deep_symbolize_keys(schema)
      end

      def security     = self.class.tool_security
      def presentation = self.class.tool_presentation

      # Delegated to Security. Supports dynamic (lambda) risk via risk_for(tool).
      def risk_level
        sec = security
        sec.respond_to?(:risk_for) ? sec.risk_for(self) : sec.risk
      end

      def risky?
        sec = security
        if sec.respond_to?(:risk_for)
          %i[medium high].include?(sec.risk_for(self))
        else
          sec.risky?
        end
      end

      # MCPToolWrapper overrides this. Built-ins are never MCP.
      def mcp?
        false
      end

      # Display label for the live tool card / approval card. Built-ins
      # render under their bare name; MCPToolWrapper appends (mcp:server).
      def display_name
        name
      end

      # Tool definition hash for LLM registration.
      def to_tool_definition
        {
          name: name,
          description: description,
          parameters: input_schema
        }
      end

      # ── Execution ──

      # Entry point called by ToolExecutor. Delegates to ruby_llm's
      # normalize → validate → execute flow, then wraps the result into
      # rubino's expected format.
      def call(arguments)
        result = super
        return if result.nil?

        # ruby_llm returns { error: "…" } on validation failure — return
        # as a plain error string so callers can use include?/match?.
        return "Error: #{result[:error]}" if result.is_a?(Hash) && result.key?(:error) && !result.key?(:output)

        # Unwrap Halt objects (halt stops conversation continuation).
        result = result.content if result.is_a?(RubyLLM::Tool::Halt)

        # Presentation: inject body_kind from the tool's Presentation class
        # when the tool returned a Hash without an explicit body_kind.
        result[:body_kind] = presentation.body_kind if result.is_a?(Hash) && result[:output] && !result.key?(:body_kind)

        result
      end

      # ── Streaming helpers ──

      def emit_chunk(text)
        return if text.nil? || text.to_s.empty?

        @stream_chunk&.call(text.to_s)
      end

      def cancellation_requested?
        @cancel_token&.cancelled?
      end

      # ── Workspace sandbox (public API) ──

      def self.workspace_root
        Workspace.primary_root
      end

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

      # True when +expanded+ resolves under ANY allowed root.
      def within_workspace?(expanded)
        return true unless workspace_strict?

        target_real = canonical_path(expanded)
        return false unless target_real

        Workspace.canonical_roots.any? do |root_real|
          target_real == root_real ||
            target_real.start_with?("#{root_real}#{File::SEPARATOR}")
        end
      end

      # Write/edit sandbox: within workspace OR under temp scratch ($TMPDIR + /tmp).
      def writable_workspace?(expanded)
        return true unless workspace_strict?
        return true if within_workspace?(expanded)

        target_real = canonical_path(expanded)
        return false unless target_real

        temp_scratch?(target_real)
      end

      # Class-level boundary accessor for ApprovalPolicy.
      def self.boundary
        @boundary ||= Class.new(self) { def name = "__boundary__" }.new
      end

      # The directory to ADD to the workspace so a write becomes allowed.
      def widen_target_for(path)
        return nil unless workspace_strict?

        expanded = expand_workspace_path(path)
        return nil if writable_workspace?(expanded)
        return nil if under_agent_home?(expanded)

        nearest_existing_dir(expanded)
      end

      # "Outside workspace" check for AUX-LLM read tools (vision).
      def outside_workspace?(expanded)
        return false unless workspace_strict?
        return false if within_workspace?(expanded)
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

      def workspace_violation_message(path)
        roots = workspace_roots
        where = roots.length == 1 ? roots.first : "any allowed root (#{roots.join(", ")})"
        "Error: refusing to access '#{path}' — outside #{where}. " \
          "Set tools.workspace_strict=false in config.yml to disable this check."
      end

      # ── Read/edit gates ──

      def read_for_edit(path)
        File.binread(path)
      end

      def to_match_bytes(str)
        str.to_s.dup.force_encoding(Encoding::BINARY)
      end

      def read_gate_error(expanded, display_path, verb:)
        return nil unless @read_tracker

        unless @read_tracker.seen?(expanded)
          return { output: "Error: must use the read tool on #{display_path} in this session before editing it. " \
                           "Read it first so the #{verb} can verify the surrounding context.",
                   error_code: :stale_read }
        end

        return nil if @read_tracker.fresh?(expanded)

        stashed = @read_tracker.mtime_at_read(expanded)
        current = File.mtime(expanded)
        { output: "Error: #{display_path} changed on disk since the last read " \
                  "(read at #{stashed&.utc&.iso8601}, now #{current.utc.iso8601}). " \
                  "Re-read the file before editing so the #{verb} reflect the current contents.",
          error_code: :stale_read }
      end

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

      protected

      # Recursively converts string hash keys to symbols.
      def deep_symbolize_keys(value)
        case value
        when Hash
          value.each_with_object({}) { |(k, v), h| h[k.to_sym] = deep_symbolize_keys(v) }
        when Array
          value.map { |v| deep_symbolize_keys(v) }
        else
          value
        end
      end

      # ── Workspace path resolution ──

      def expand_workspace_path(path)
        str = path.to_s
        return File.expand_path(str) if str.start_with?(File::SEPARATOR, "~")

        File.expand_path(str, Workspace.current_cwd)
      end

      def nearest_existing_dir(expanded)
        dir = File.dirname(expanded)
        dir = File.dirname(dir) until File.directory?(dir) || dir == File.dirname(dir)
        File.directory?(dir) ? dir : nil
      end

      def temp_scratch_roots
        [ENV.fetch("TMPDIR", nil), "/tmp"].filter_map do |p|
          next if p.nil? || p.empty? || !File.directory?(p)

          File.realpath(File.expand_path(p))
        rescue StandardError
          nil
        end.uniq
      end

      def temp_scratch?(target_real)
        return false if under_agent_home?(target_real)

        temp_scratch_roots.any? do |root|
          target_real == root || target_real.start_with?("#{root}#{File::SEPARATOR}")
        end
      end

      def canonical_path(path, symlink_hops = 0)
        return nil if path.nil? || path.to_s.empty?

        expanded = File.expand_path(path.to_s)
        return File.realpath(expanded) if File.exist?(expanded)

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

      def under_agent_home?(expanded)
        home = Rubino.home_path
        return false if home.nil? || home.to_s.empty?

        home_real   = (File.realpath(home) if File.exist?(home)) || File.expand_path(home)
        target_real = canonical_path(expanded)
        return false unless target_real

        target_real == home_real || target_real.start_with?("#{home_real}#{File::SEPARATOR}")
      rescue StandardError => e
        Rubino.logger&.warn(event: "tools.under_agent_home_failed",
                            error: e.message, error_class: e.class.name)
        false
      end
    end
  end
end
