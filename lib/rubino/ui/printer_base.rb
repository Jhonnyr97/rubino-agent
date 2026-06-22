# frozen_string_literal: true

require "pastel"

module Rubino
  module UI
    # Shared printing behaviour for terminal-based UI adapters.
    #
    # Subclasses must implement #color_for(role) returning a Pastel method name
    # (e.g. :cyan, :green) so that message formatting stays here while each
    # adapter controls its own color scheme.
    class PrinterBase < Base
      def initialize
        @pastel = Pastel.new
      end

      def info(message)    = puts_colored(color_for(:info), message)
      def success(message) = puts_colored(color_for(:success), "✓ #{message}")
      def warning(message) = puts_colored(color_for(:warning), "⚠ #{message}")
      def error(message)   = puts_colored(color_for(:error),   "✗ #{message}")
      def status(message)  = puts_colored(color_for(:status),  message)

      def stream(chunk)
        text = chunk[:text].to_s
        $stdout.print text
        $stdout.flush
      end

      def stream_end
        $stdout.puts
      end

      def tool_started(name, arguments: nil, at: nil)
        puts_colored(color_for(:tool), "  → Running tool: #{name}")
      end

      def tool_finished(name, result: nil)
        suffix = result ? " (#{result.truncated_preview})" : ""
        puts_colored(color_for(:tool), "  ← #{name} done#{suffix}")
      end

      def compression_started(at: nil)
        puts_colored(color_for(:muted), "  ⟳ Compacting context...")
      end

      def compression_finished(metadata, at: nil)
        saved = metadata[:saved_tokens] || 0
        puts_colored(color_for(:muted), "  ⟳ Context compacted (saved #{saved} tokens)")
      end

      def job_enqueued(_type) = nil
      def job_started(_type)  = nil
      def job_finished(_type) = nil

      def blank_line = $stdout.puts

      # Default fallback. CLI overrides to render the
      # `┄ HH:MM · mode → plan ┄` free-line variant.
      def mode_changed(name, previous: nil)
        arrow = previous && previous != name ? " #{previous} → #{name}" : " #{name}"
        puts_colored(color_for(:muted), "  ⟳ mode#{arrow}")
      end

      private

      # Subclasses override to map a semantic role to a Pastel method symbol.
      # @param role [Symbol] e.g. :info, :success, :warning, :error, :tool, :muted
      # @return [Symbol, nil] Pastel method name, or nil to skip coloring
      def color_for(_role)
        nil
      end

      # CWE-150 render-sink defense (#564, same class as #563). Many rows printed
      # here interpolate UNTRUSTED text — most acutely the /agents handler's
      # subagent name / ask_question / error / activity_log / last_activity /
      # approval_command, all built from a child's tool args (an attacker-named
      # workspace file) or model-chosen strings. Printed verbatim, an embedded
      # `\e[2J` (clear) / `\e]0;…\a` (title-set) / `\e[?1049h` (alt-screen) / CR /
      # BEL would reach the TTY and EXECUTE — no approval, no gesture. Neutralize
      # every dangerous control byte at THIS chokepoint (the single seam every
      # info/success/warning/error/status row flows through), rendering them as
      # visible caret notation. The SGR-preserving variant keeps rubino's OWN
      # inert color spans (e.g. the watch frame's `pastel.yellow("●")`) intact
      # while the outer #color wrap is applied AFTER, around the now-safe text.
      def puts_colored(color, text)
        safe = Rubino::Util::Output.sanitize_terminal_keep_sgr(text.to_s)
        line = color ? @pastel.send(color, safe) : safe
        $stdout.puts line
      end
    end
  end
end
