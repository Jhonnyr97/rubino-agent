# frozen_string_literal: true

module Rubino
  module UI
    # Single renderer for "how a tool call is shown to the human", declared
    # per-tool via the `summary` DSL on Tools::Base. Every surface — the
    # interactive card open-row, the live status footer, the approval prompt,
    # the one-shot trace, and the yolo warning — routes through this ONE
    # function so the label vocabulary and security filters are never duplicated.
    #
    # Contexts:
    #   :status   → String,         single line, MAY truncate with … (ONLY here)
    #   :approval → Array<String>,  full, wrap to width, NEVER truncates
    #   :timeline → Array<String>,  full, wrap to width
    #   :trace    → Array<String>,  full, unwrapped (machine-greppable)
    #
    # Security: every value goes through Util::SecretsMask + Util::Output.
    # sanitize_terminal — losing either is a security regression (CWE-150 /
    # credential-leak).
    module CallSummary
      # Lightweight context passed to `summary` blocks that accept arity 2.
      # Exposes `rel(path)` to format paths relative to the workspace root
      # for blast-radius clarity.
      Ctx = Struct.new(:workspace_root) do
        # Returns the given path relative to the workspace root, or the
        # absolute path when it cannot be relativised.
        def rel(path)
          str = path.to_s
          return str if str.empty? || workspace_root.nil?

          expanded = File.expand_path(str)
          ws = File.expand_path(workspace_root.to_s)
          return Util::Output.sanitize_terminal(expanded) unless expanded.start_with?("#{ws}/") || expanded == ws

          rel = expanded == ws ? "." : expanded[(ws.length + 1)..]
          Util::Output.sanitize_terminal(rel)
        rescue StandardError
          Util::Output.sanitize_terminal(str)
        end
      end

      module_function

      # The single entry point. Returns String for :status, Array<String> for
      # every other context.
      def render(tool, args, width:, context:)
        args    = normalize_args(args)
        ctx     = build_ctx
        label   = resolve_label(tool, args, ctx)
        display = tool_display_name(tool)
        head    = label ? "#{display} #{label}" : display.to_s

        case context
        when :status
          head = truncate(head, width)
          head
        when :trace
          build_trace_lines(head)
        when :approval, :timeline
          build_full_lines(head, width)
        else
          [head]
        end
      end

      # Resolves and returns just the label string for a tool call (masked,
      # sanitised, workspace-relative paths via the summary DSL), or nil when
      # no identifiable label can be produced. Exposed so the approval prompt
      # can drive the single-arg inline line through the SAME
      # mask+sanitize+label primitives as the summary card.
      def label_for(tool, args)
        args = normalize_args(args)
        ctx  = build_ctx
        resolve_label(tool, args, ctx)
      end

      # ── internal helpers ──

      def resolve_label(tool, args, ctx)
        spec = tool.class.resolve_summary if tool.class.respond_to?(:resolve_summary)
        return pick_hint_fallback(args) unless spec

        if spec.block?
          call_block(spec, args, ctx)
        elsif spec.key
          raw = args[spec.key] || args[spec.key.to_s]
          return nil if raw.nil? || raw.to_s.empty?

          masked = mask_and_sanitize(raw, key: spec.key)
          if spec.relative_to == :workspace
            ctx.rel(masked)
          else
            first_line(masked)
          end
        end
      end

      def pick_hint_fallback(args)
        picked = ToolLabel.pick_hint(args)
        return nil unless picked

        _key, raw = picked
        mask_and_sanitize(raw, key: picked[0])
      end

      def call_block(spec, args, ctx)
        blk = spec.proc
        if blk.arity == 2
          mask_and_sanitize(blk.call(args, ctx).to_s, key: nil)
        else
          mask_and_sanitize(blk.call(args).to_s, key: nil)
        end
      end

      def build_trace_lines(head)
        [head]
      end

      def build_full_lines(head, width)
        lines = []
        if head.length <= width
          lines << head
        else
          lines.concat(wrap_line(head, width))
        end
        lines
      end

      def tool_display_name(tool)
        if tool.respond_to?(:display_name)
          tool.display_name
        elsif tool.respond_to?(:name)
          tool.name
        else
          tool.class.name.to_s
        end
      end

      # Wrap a long line at width, never truncating — the user must see
      # everything they're approving. Breaks at whitespace when possible;
      # falls back to a hard cut for a single token longer than width.
      def wrap_line(line, width)
        return [line] if width <= 0 || line.length <= width

        result = []
        remaining = line
        continuation = "  "

        while remaining && remaining.length > width
          # Strip continuation indent prepended by a previous iteration so
          # the break search operates on the real content.
          remaining = remaining.sub(/\A  /, "")

          break_at = remaining.rindex(/\s/, width)
          if break_at && break_at > 0
            result << remaining[0, break_at]
            remaining = remaining[(break_at + 1)..]
          else
            # No whitespace break point — hard cut at width.
            result << remaining[0, width]
            remaining = remaining[width..]
          end
          remaining = remaining ? "#{continuation}#{remaining}" : nil
        end
        result << remaining if remaining && !remaining.empty?
        result
      end

      # Truncate a single line to width with an ellipsis.
      def truncate(text, max)
        return text if max <= 0 || text.length <= max

        "#{text[0, max - 1]}…"
      end

      def mask_and_sanitize(value, key: nil)
        masked = Util::SecretsMask.mask_value(value, key: key).to_s
        Util::Output.sanitize_terminal(masked)
      end

      def first_line(text)
        text.to_s.lines.first.to_s.strip
      end

      def build_ctx
        Ctx.new(Workspace.primary_root)
      end

      # Normalize string-keyed args to symbols so summary blocks (which use
      # symbol keys) work correctly with real JSON tool-call arguments.
      # Non-Hash args (bare strings, etc.) pass through unchanged.
      def normalize_args(args)
        return args unless args.is_a?(Hash) && args.respond_to?(:transform_keys)

        args.transform_keys(&:to_sym)
      end
    end
  end
end
