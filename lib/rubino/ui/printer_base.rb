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
        emit_blank
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

      def blank_line = emit_blank

      # Default fallback. CLI overrides to render the
      # `┄ HH:MM · mode → plan ┄` free-line variant.
      def mode_changed(name, previous: nil)
        arrow = previous && previous != name ? " #{previous} → #{name}" : " #{name}"
        puts_colored(color_for(:muted), "  ⟳ mode#{arrow}")
      end

      # ─────────────────────────────────────────────────────────────────────
      # THE OUTPUT FUNNEL (CWE-150 defense by construction — #563/#564/#565-568)
      # ─────────────────────────────────────────────────────────────────────
      #
      # Every byte rubino writes to the terminal flows through ONE of two paths
      # here, and #write_line below is the ONLY place that touches $stdout. The
      # per-sink `sanitize_terminal` discipline we used before was leaky: each
      # new $stdout.puts had to REMEMBER to defang its interpolated text, and the
      # ones that forgot became the escape-injection bugs. Centralizing the write
      # makes "raw escapes reach the TTY" impossible to express in caller code —
      # there is no longer a sink that bakes untrusted text + color into one
      # string and prints it raw.
      #
      # PATH 1 — #emit / #emit_line: UNTRUSTED text + an optional rubino style.
      #   The text (a tool-arg filename, a subagent name, a model-chosen string,
      #   steered user input) is run through #sanitize_terminal, which STRIPS
      #   every escape — ESC/CSI/OSC/C1/BEL/CR become visible caret notation
      #   (ESC → "^[") — and ONLY THEN is rubino's own colour applied around the
      #   now-inert text. An embedded `\e[2J` / `\e]0;…\a` / `\e[?1049h` can
      #   never reach the emulator because it is no longer an escape by the time
      #   the style wrap (and the write) happen. Callers pass a SEMANTIC style
      #   symbol (e.g. :dim, :cyan) — they never hand us a pre-coloured string,
      #   so they cannot smuggle escapes in via the colour either.
      #
      # PATH 2 — #emit_styled: rubino's OWN, already-styled content (markdown
      #   render output, the live region, a row that legitimately interpolates a
      #   `@pastel.yellow("●")` glyph). This is run through
      #   #sanitize_terminal_keep_sgr, which strips every DANGEROUS control byte
      #   exactly like path 1 but PRESERVES inert SGR colour escapes, so rubino's
      #   styling survives while cursor-move / clear / title-set / clipboard
      #   sequences still cannot pass. Use this ONLY for content rubino itself
      #   built; never route untrusted text here (it would keep that text's SGR).
      #
      # So untrusted text can ONLY render via path 1 (fully defanged), and
      # rubino's own styling survives via path 2 — by construction, not by each
      # sink remembering to call the sanitizer.

      # PATH 1. Untrusted +text+ → strip ALL escapes → apply +style+ → write.
      # +style+ is a semantic Pastel method symbol (:dim, :cyan, :red, …), an
      # Array of them for a compound decoration (e.g. [:red, :bold]), or nil for
      # no colour. The text is treated as hostile; escapes become visible caret
      # notation, and the style is applied AFTER sanitizing so it can only wrap
      # already-inert text.
      def emit(text, style: nil)
        safe = Rubino::Util::Output.sanitize_terminal(text.to_s)
        write_line(style ? @pastel.decorate(safe, *Array(style)) : safe)
      end
      alias emit_line emit

      # PATH 2. rubino's OWN pre-built styled +prebuilt+ → strip dangerous
      # control bytes, KEEP rubino's SGR colour → write. For markdown render
      # output, the live region, and rows that interpolate a rubino-coloured
      # glyph. NEVER pass untrusted text here.
      def emit_styled(prebuilt)
        write_line(Rubino::Util::Output.sanitize_terminal_keep_sgr(prebuilt.to_s))
      end

      # A blank line. Routed through the funnel so $stdout stays private to it.
      def emit_blank = write_line

      # PATH 1 (compose). A TRUSTED rubino-built prefix (a coloured glyph rubino
      # chose, e.g. `@pastel.cyan("●")`) + an UNTRUSTED +body+ that gets the
      # full PATH-1 defang before its own style wrap. The two are joined and
      # written through the single seam.
      #
      # Cat 2 of the phase-2 migration: the `● <name>` activity/delegation rows
      # interpolate a trusted cyan glyph next to a model-chosen name/preview. A
      # plain #emit("#{glyph} #{name}") would defang the glyph's OWN colour (the
      # caret leak); #emit_styled("#{glyph} #{@pastel.dim(name)}") would KEEP the
      # untrusted name's SGR (the injection leak). This composes correctly: the
      # glyph keeps its trusted colour, the body is stripped of every escape and
      # THEN wrapped in +style+, and the join is written verbatim — the glyph's
      # SGR and the body style are the only escapes that survive. +prefix+ must
      # be rubino-built (never untrusted); +body+ is always treated as hostile.
      def emit_glyph(prefix, body, style: nil)
        safe = Rubino::Util::Output.sanitize_terminal(body.to_s)
        styled = style ? @pastel.decorate(safe, *Array(style)) : safe
        write_line("#{prefix}#{styled}")
      end

      # A rubino-built CURSOR-CONTROL frame for the live region / status spinner /
      # stream tail (Cat 4 — the hot path). These legitimately carry rubino's OWN
      # cursor escapes (`\r`, `\e[2K`, cursor moves) that a defang would strip, so
      # this writes +raw+ THROUGH the single $stdout seam WITHOUT stripping cursor
      # control, then flushes (transient frames must paint immediately — they are
      # not committed lines).
      #
      # CONTRACT: the caller has ALREADY defanged every UNTRUSTED span it
      # interpolated (model tail text via #sanitize_terminal at #margined_tail /
      # #show_reasoning_tail; the status label/hint via #safe at build time). Only
      # rubino's own frame escapes pass here. This exists so even the live/stream
      # writes go through ONE seam — there is no direct $stdout.print left in the
      # render path — without changing the print+flush timing the smooth-cadence
      # measurement depends on.
      def emit_frame(raw)
        write_raw(raw.to_s)
      end

      private

      # Subclasses override to map a semantic role to a Pastel method symbol.
      # @param role [Symbol] e.g. :info, :success, :warning, :error, :tool, :muted
      # @return [Symbol, nil] Pastel method name, or nil to skip coloring
      def color_for(_role)
        nil
      end

      # The SINGLE seam that writes a committed line to the terminal. Keeping
      # $stdout access here (and nowhere else in the funnel) is what makes the
      # CWE-150 guarantee structural: there is exactly one write, and both ways
      # to reach it (#emit, #emit_styled) have already neutralized escapes.
      def write_line(line = nil)
        line.nil? ? $stdout.puts : $stdout.puts(line)
      end

      # The partner seam for TRANSIENT cursor-control frames (#emit_frame): a
      # raw, no-newline print + flush. Kept here, alongside #write_line, so EVERY
      # byte rubino writes — committed lines AND live frames — still funnels
      # through this one file's $stdout access. The print/flush pair is the exact
      # shape the live region used before (no extra buffering), so cadence is
      # unchanged.
      def write_raw(raw)
        $stdout.print(raw)
        $stdout.flush
      end

      # Re-expressed on PATH 2. The info/success/warning/error/status rows above
      # interpolate rubino's own glyphs/labels around text that MAY be untrusted
      # (e.g. an /agents row's subagent name) — historically defanged with the
      # SGR-preserving sanitizer so rubino's colour survived. That is exactly
      # #emit_styled's contract, so this now just forwards the colour-wrapped
      # line into the funnel. (Phase 2 will split the genuinely-untrusted callers
      # onto #emit so even their SGR can't pass; for the centralized base rows it
      # is a clean 1:1 onto the funnel today.)
      def puts_colored(color, text)
        emit_styled(color ? @pastel.send(color, text.to_s) : text.to_s)
      end
    end
  end
end
