# frozen_string_literal: true

require_relative "tools/base"
require_relative "tools/result"
require_relative "tools/tool_security"
require_relative "tools/tool_presentation"
require_relative "tools/registry"
require_relative "attachments/classify"
require_relative "attachments/policy"
require_relative "llm/content_builder"
# LLM::AuxiliaryClient is autoloaded lazily by Zeitwerk — referenced only
# inside #ask_aux at call time, never at require time.

module Rubino
  # Thin sugar layer over Tools::Base that synthesises ToolSecurity /
  # ToolPresentation / Tools::Result under the hood — same trick
  # CustomToolLoader#build already uses.
  #
  # Every existing tool keeps working unchanged.  Rubino::Tool is a
  # strict superset: the old `param :x, desc:` spelling, `params do…end`
  # blocks, `security SomeClass`, `presentation SomeClass`, and bare-String
  # returns all still work.
  #
  # North star: simple / easy / magic via conventions, every default
  # overridable.
  #
  #   class MyTool < Rubino::Tool
  #     describe "Does something useful"
  #     string :input, "The input text"
  #     integer :count, "How many", default: 1
  #     risk :low
  #
  #     def execute(input:, count: 1)
  #       ok(input * count, metrics: "#{count}×")
  #     end
  #   end
  class Tool < Tools::Base
    # Sentinel to distinguish "no default given" from explicit `default: nil`.
    NO_DEFAULT = Object.new

    # Append-only list of every concrete, named subclass — never cleared
    # during a process. Populated by the `inherited` hook on first boot;
    # replayed on every `finalize_registrations!` (idempotent — Registry.register
    # is an upsert by name) so re-registration after a Registry.reset! just
    # re-populates the freshly-reset registry from the same list.
    @_tool_subclasses = []

    class << self
      # ── Inheritance hook (auto-register + footgun fix) ──

      def inherited(subclass)
        super

        # Kill the class-instance-variable inheritance footgun
        # (base.rb:16-21).  Class-instance variables do NOT inherit in
        # Ruby; when you write `class Child < ParentTool`, every
        # class-level declaration silently disappears.  Copy them all
        # down so the child keeps the parent's security, presentation,
        # redaction profile, image guards, and aux task.
        %i[
          @tool_security @tool_presentation @live_card_header
          @live_card_after
          @redaction_profile @image_params @aux_task
          @rubino_risk_level @rubino_sandbox @rubino_require_read
          @rubino_allow_widening
        ].each do |var|
          next unless instance_variable_defined?(var)

          subclass.instance_variable_set(var, instance_variable_get(var))
        end

        # Collect every concrete, NAMED subclass for deferred registration.
        # inherited fires BEFORE the class body runs (before `describe`,
        # `string`, and any `#name` override), so we collect here and
        # register AFTER all requires complete (see finalize_registrations!).
        # Anonymous classes (e.g. test fixtures via Class.new) are skipped —
        # their name is nil and Registry.register would crash inside Base#name.
        # Abstract base classes call `abstract!` to opt out.
        # MCP / custom-tool paths are unchanged.
        return if subclass.abstract_tool? || subclass.name.nil?

        @_tool_subclasses << subclass
      end

      # Called after all tool files are loaded to register the collected
      # subclasses.  By this point their class bodies are fully defined,
      # so #name overrides and per-instance init reading class-level
      # config work correctly.
      #
      # Replays the append-only @_tool_subclasses list (populated by
      # `inherited` on first boot). Registry.register is an idempotent
      # upsert by name (registry.rb: `@tools[tool.name] = tool`), so
      # replaying after a Registry.reset! just re-populates the
      # freshly-reset registry — no ObjectSpace, no divergence between
      # first boot and re-registration.
      def finalize_registrations!
        @_tool_subclasses.each do |sc|
          next if sc.abstract_tool?

          Tools::Registry.register(sc.new)
        end
      end

      # Test-only: clear the append-only subclass list so test isolation
      # doesn't leak.
      def _clear_pending_registrations!
        @_tool_subclasses.clear
      end

      def abstract!
        @abstract_tool = true
      end

      def abstract_tool?
        @abstract_tool == true
      end

      # ── ONE param spelling (unified positional-desc) ──
      #
      #   string :name, "What to call it", default: "world"
      #   integer :count, "How many", default: 1
      #   boolean :verbose, "Chatty?", required: false
      #   string :mode, "Output mode", enum: %w[diff json plain]
      #
      # `required` is inferred: explicit `required:` wins, otherwise
      # presence of any `default:` (even nil) means optional, absence means
      # required.  `default:` and `enum:` are injected into the schema
      # description so the LLM sees them, not just the Ruby signature.
      #
      # The block-based `params do…end` DSL still works alongside these.

      def string(name, desc = nil, required: nil, default: NO_DEFAULT, enum: nil)
        has_default = default != NO_DEFAULT
        required = !has_default if required.nil?
        full_desc = build_desc(desc, default: (default if has_default), enum: enum)

        if enum && has_default && !enum.include?(default.to_s)
          raise ArgumentError,
                "#{name}: default #{default.inspect} not in enum #{enum.inspect}"
        end

        param name, type: :string, desc: full_desc, required: required
      end

      def integer(name, desc = nil, required: nil, default: NO_DEFAULT)
        has_default = default != NO_DEFAULT
        required = !has_default if required.nil?
        full_desc = build_desc(desc, default: (default if has_default))
        param name, type: :integer, desc: full_desc, required: required
      end

      def boolean(name, desc = nil, required: nil, default: NO_DEFAULT)
        has_default = default != NO_DEFAULT
        required = !has_default if required.nil?
        full_desc = build_desc(desc, default: (default if has_default))
        param name, type: :boolean, desc: full_desc, required: required
      end

      def array(name, desc = nil, required: nil, default: NO_DEFAULT)
        has_default = default != NO_DEFAULT
        required = !has_default if required.nil?
        full_desc = build_desc(desc, default: (default if has_default))
        param name, type: :array, desc: full_desc, required: required
      end

      def object(name, desc = nil, required: nil, default: NO_DEFAULT)
        has_default = default != NO_DEFAULT
        required = !has_default if required.nil?
        full_desc = build_desc(desc, default: (default if has_default))
        param name, type: :object, desc: full_desc, required: required
      end

      # ── Image param (with built-in egress guards) ──
      #
      # Declares a string param AND registers it for automatic egress
      # guarding.  At call time, BEFORE #execute sees the argument, the
      # full pipeline from vision_tool.rb:42-73 fires:
      #   workspace containment → existence → regular-file →
      #   extension allowlist → egress kill-switch → content-sniff
      #
      # If any guard fails the tool returns the same error message the
      # old hand-wired path produced — the author never sees the guard
      # code, and it CAN'T be forgotten.

      def image(name, desc = nil, required: nil, default: NO_DEFAULT)
        has_default = default != NO_DEFAULT
        required = !has_default if required.nil?
        full_desc = build_desc(desc, default: (default if has_default))
        param name, type: :string, desc: full_desc, required: required
        @image_params ||= []
        @image_params << name.to_sym
      end

      def image_params
        @image_params || []
      end

      # ── Convenience aliases ──

      # `describe "…"` is identical to RubyLLM's `description "…"`.
      def describe(text)
        description(text)
      end

      # Shortcut for `redaction_profile`.
      #   redaction :none   # disable secret scrubbing (EXPLICIT opt-in)
      def redaction(profile)
        redaction_profile(profile)
      end

      # Declares an auxiliary-LLM dependency (registry gating).
      #   uses_aux :vision
      def uses_aux(task)
        @aux_task = task
      end

      attr_reader :aux_task

      private

      def build_desc(base, default: nil, enum: nil)
        parts = [base].compact
        parts << "(default: #{default.inspect})" if default
        parts << "(allowed: #{enum.join(", ")})" if enum
        parts.join(" ")
      end
    end

    # The DSL base class itself must never auto-register.
    abstract!

    # ── Result helpers ──

    # Returns a success result hash the ToolExecutor understands.
    #
    #   ok("Done")
    #   ok("42 lines", metrics: "0.1s", diff: diff_output)
    #   ok("Here", json: {key: "val"})
    #   ok("Saved", artifact: {path:, filename:, content_type:, byte_size:})
    #
    # A bare String return still works unchanged.

    # rubocop:disable Metrics/ParameterLists
    def ok(text = "", metrics: nil, diff: nil, json: nil, table: nil, artifact: nil, label: nil)
      result = { output: text.to_s }
      result[:metrics] = metrics if metrics

      if diff
        result[:body] = diff
        result[:body_kind] = :diff
      elsif json
        result[:body] = json.is_a?(String) ? json : JSON.pretty_generate(json)
        result[:body_kind] = :json
      elsif table
        result[:body] = table
        result[:body_kind] = :table
      end

      result[:artifact] = artifact if artifact
      result[:label] = label if label

      result
    end
    # rubocop:enable Metrics/ParameterLists

    # Returns an errorish result.  The ToolExecutor recognises the
    # "Error:" prefix and renders ✗ instead of ✓.
    #
    #   error("file not found: #{path}")
    #   error("permission denied", code: :outside_workspace)
    #
    # Avoid `fail` — it collides with Kernel#fail.

    def error(message, code: nil)
      result = { output: "Error: #{message}" }
      result[:error_code] = code if code
      result
    end

    # ── Image egress guard (applied automatically before #execute) ──

    def call(arguments)
      self.class.image_params.each do |param_name|
        val = arguments[param_name.to_s] || arguments[param_name.to_sym]
        next if val.nil? || val.to_s.empty?

        guard_result = guard_image(val.to_s)
        return guard_result if guard_result
      end

      super
    end

    # ── Aux helpers ──

    # Delegates to the aux LLM.  Uses the task declared via `uses_aux`
    # by default; pass `task:` to target a specific aux (e.g. when a
    # tool talks to multiple aux models — vision + compression).
    #
    # `image:` passes the file path through ruby_llm's native
    # `with:` slot — the same route the primary model uses for
    # native vision, NOT an OpenAI-style content array.
    def ask_aux(prompt, task: nil, image: nil)
      task ||= self.class.aux_task || :vision
      opts = { task: task, messages: [{ role: "user", content: prompt }] }
      opts[:image_paths] = [image] if image
      LLM::AuxiliaryClient.new.call(**opts)
    end

    # Builds an artifact result hash for an image, writing bytes to a
    # workspace temp file when raw bytes are passed.  The ToolExecutor
    # emits the ARTIFACT_CREATED event automatically when it sees the
    # `:artifact` key.
    def attach_image(bytes_or_path, filename:, caption: nil)
      path, size = resolve_image_path(bytes_or_path, filename)

      content_type = image_content_type_for(filename)
      artifact = {
        path: path,
        filename: filename,
        content_type: content_type,
        byte_size: size
      }

      output = caption || "Attached #{filename} (#{size} bytes) as a downloadable artifact."
      { output: output, metrics: "#{size} bytes", artifact: artifact }
    end

    private

    # ── Image guard pipeline (mirrors vision_tool.rb:42-73) ──

    def guard_image(path_str)
      expanded = expand_workspace_path(path_str)

      return outside_workspace_message(path_str) if outside_workspace?(expanded)
      return "Error: file not found: #{path_str}" unless File.exist?(expanded)
      return "Error: not a regular file: #{path_str}" unless File.file?(expanded)

      ext = File.extname(expanded).downcase
      unless LLM::ContentBuilder::SUPPORTED_IMAGE_TYPES.include?(ext)
        return "Error: unsupported image extension '#{ext}'. " \
               "Supported: #{LLM::ContentBuilder::SUPPORTED_IMAGE_TYPES.join(", ")}"
      end

      # Egress kill-switch: keyed on the DECLARED aux task, not hardcoded
      # :vision.  When the tool uses a non-vision aux (e.g. :ocr), the
      # vision-specific kill-switch doesn't apply — add task-specific
      # policy checks here as new aux tasks gain egress controls.
      if image_egress_blocked?
        return "Error: image egress is disabled by config " \
               "(attachments.policy.aux_vision_egress: false). " \
               "The tool will not send image bytes to the auxiliary model."
      end

      classification = Attachments::Classify.call(expanded)
      unless classification&.safe && classification.kind == :image
        return "Error: '#{path_str}' is not a valid image (extension spoof or corrupt file?). " \
               "Its content is not a recognised image format, so nothing was sent to the vision model."
      end

      nil
    end

    def image_egress_blocked?
      case self.class.aux_task
      when :vision, nil
        !Attachments::Policy.aux_vision_egress?
      else
        false # other aux tasks don't (yet) have an egress kill-switch
      end
    end

    def resolve_image_path(bytes_or_path, filename)
      if bytes_or_path.is_a?(String) && File.exist?(bytes_or_path)
        expanded = File.expand_path(bytes_or_path)
        [expanded, File.size(expanded)]
      else
        raw = bytes_or_path.is_a?(String) ? bytes_or_path : bytes_or_path.to_s
        tmp_dir = Dir.mktmpdir("rubino_artifact")
        tmp_path = File.join(tmp_dir, filename)
        File.binwrite(tmp_path, raw)
        [tmp_path, raw.bytesize]
      end
    end

    def image_content_type_for(filename)
      ext = File.extname(filename.to_s).sub(/\A\./, "").downcase
      # Reuse AttachFileTool::CONTENT_TYPES (lazy — Zeitwerk autoloads on
      # first reference).  Falls back to octet-stream for unlisted exts.
      ct = Tools::AttachFileTool::CONTENT_TYPES[ext]
      ct || "application/octet-stream"
    end
  end
end
