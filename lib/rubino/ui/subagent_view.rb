# frozen_string_literal: true

require "pastel"
require "zlib"

module Rubino
  module UI
    # Nested UI adapter for a running subagent (the `task` tool).
    #
    # While the parent loop delegates to a subagent, the child runs its own
    # isolated Agent::Runner. By default that child is wired with UI::Null, so
    # its activity is invisible. This adapter makes the child's TOOL ACTIVITY
    # visible INLINE — compact rows indented under the parent's
    # "● delegated → X" delegation boundary, in a per-subagent color — so the
    # user can watch what the subagent is doing live.
    #
    # DISPLAY ONLY. This adapter writes to $stdout (which, during a parent turn,
    # is the composer proxy → committed above the bottom composer like every
    # other timeline row). It never touches the parent loop's `messages` or the
    # parent recorder: the result-only contract is unchanged. The parent model
    # still receives ONLY the subagent's final result (the `task` tool result).
    #
    # COLLAPSED-CARD MODE (Variant A — kills the flood, #124): instead of
    # writing one $stdout row per child tool call (which buried the parent
    # prompt), tool_started/tool_finished now feed the BackgroundTasks REGISTRY
    # entry for this run (last_activity + a tool counter + a bounded recent-ring)
    # and ask the parent UI to repaint its collapsed live CARD. The card shows a
    # single in-place line per subagent (`▸ sa_… · explore · running · N tools ·
    # Ns · <last_activity>`) that updates without scrolling — see UI::CLI
    # #set_subagent_cards / UI::SubagentCards. The /agents <id> drill-in tails the
    # same registry ring for the live recent: list (#71).
    #
    # The view is wired with the entry id at construction (TaskTool builds it per
    # background run). With no id (legacy/foreground synchronous path, tests) it
    # falls back to the OLD inline rows so the synchronous delegation surface and
    # its specs are unchanged.
    #
    # Inline (legacy) format, 2-space extra indent under the delegation row:
    #   `    ⟂ explore · read lib/foo.rb`
    #   `    ⟂ explore · ✓ grep · 3 matches`
    #
    # Noise control:
    #   - stream / stream_end / assistant_text / thinking_started are SUPPRESSED
    #     (the subagent's prose isn't shown — only its steps and the final
    #     result, which the parent already prints as "✓ X: result");
    #   - note / status / info render as dim nested lines (low-noise) ONLY in the
    #     legacy inline path; in card mode they fold into the registry too;
    #   - confirm: in card mode it does NOT auto-deny — it surfaces the approval
    #     on the card and parks the child on a per-entry gate (Option 2; wired by
    #     TaskTool). With no approval handler (legacy/foreground) it auto-DENIES
    #     so a subagent never blocks on a prompt no one can answer.
    class SubagentView < Base
      # Deterministic per-subagent palette. Chosen by hashing the agent name so
      # the same subagent always renders in the same color (no Math.random),
      # and concurrent/sequential delegations to different subagents stay
      # visually distinct. All names are valid Pastel foreground colors.
      PALETTE = %i[cyan magenta blue yellow green bright_cyan].freeze

      # Nested-row indent: 2 spaces beyond the CLI's own 2-space body indent so
      # the subagent's steps read as nested under the "● delegated → X" row.
      INDENT = "    "

      # Glyph prefixing every subagent activity row.
      GLYPH = "⟂"

      # @param entry_id [String, nil] the BackgroundTasks entry this view feeds
      #   in card mode. nil ⇒ legacy inline-row mode (synchronous/foreground path).
      # @param parent_ui [UI::CLI, nil] the parent CLI whose live region hosts the
      #   collapsed card; #set_subagent_cards repaints it. Captured at spawn on the
      #   parent thread (the child thread has no access to the parent's UI).
      # @param approve [#call, nil] in card mode, the approval handler TaskTool
      #   wires: called with (question, scope:, command:) and returns the boolean
      #   decision. nil ⇒ #confirm auto-denies (legacy behavior).
      def initialize(agent_name:, out: $stdout, pastel: Pastel.new,
                     entry_id: nil, parent_ui: nil, approve: nil)
        @agent_name = agent_name.to_s
        @out        = out
        @pastel     = pastel
        @color      = PALETTE[color_index(@agent_name)]
        @entry_id   = entry_id
        @parent_ui  = parent_ui
        @approve    = approve
      end

      # The color this view paints its rows in (exposed for tests).
      attr_reader :color

      # True when this view feeds a registry entry (collapsed-card mode) rather
      # than flooding $stdout with per-tool rows (legacy inline mode).
      def card_mode?
        !@entry_id.nil?
      end

      # --- Rendered: tool activity (the "what it's doing") -------------------

      # Card mode: record the tool start on the registry entry (last_activity +
      # tool counter) and repaint the parent's collapsed card — NO $stdout row, so
      # a read-heavy child never floods the parent terminal (#124). Legacy mode:
      # the old inline `    ⟂ explore · read lib/foo.rb` row.
      def tool_started(name, arguments: nil, at: nil)
        hint = args_hint(arguments)
        if card_mode?
          activity = hint ? "#{name} #{hint}" : name.to_s
          Tools::BackgroundTasks.instance.record_tool_started(@entry_id, activity)
          repaint_cards
        else
          body = hint ? "#{name} #{hint}" : name.to_s
          row(body)
        end
      end

      # Card mode: append the terse finish line to the entry's recent-ring (which
      # the /agents drill-in tails) and repaint. Legacy mode: the old inline row.
      def tool_finished(name, result: nil)
        failed = result.respond_to?(:success?) && !result.success?
        icon   = failed ? "✗" : "✓"
        suffix = result_metric(result)
        body   = suffix ? "#{icon} #{name} · #{suffix}" : "#{icon} #{name}"
        if card_mode?
          Tools::BackgroundTasks.instance.record_tool_finished(@entry_id, body)
          repaint_cards
        else
          row(body)
        end
      end

      # tool_body / tool_chunk: the child's tool previews/streamed chunks. Kept
      # quiet to stay low-noise — the start/finish rows already say what ran.
      def tool_body(_text, kind: :plain); end
      def tool_chunk(_name, _chunk); end

      # --- Suppressed: the child's prose / token stream ---------------------

      def stream(_chunk); end
      def stream_end; end
      def assistant_text(_text); end
      def body(_text); end
      def thinking_started; end
      def replay_user_input(_text, at: nil); end
      def table(headers:, rows:); end

      # --- Low-noise: dim nested annotations -------------------------------

      # In card mode these fold away (the card is the only surface); in legacy
      # inline mode they keep their dim nested rows.
      def note(text)   = card_mode? ? nil : dim_row(text)
      def status(text) = card_mode? ? nil : dim_row(text)
      def info(text)   = card_mode? ? nil : dim_row(text)

      def success(message) = card_mode? ? nil : row("✓ #{message}")
      def warning(message) = card_mode? ? nil : row("⚠ #{message}")
      def error(message)   = card_mode? ? nil : row("✗ #{message}")

      # --- Suppressed lifecycle chrome ------------------------------------

      def separator; end
      def blank_line; end
      def compression_started(at: nil); end
      def compression_finished(_metadata, at: nil); end
      def job_enqueued(_type); end
      def job_started(_type); end
      def job_finished(_type); end
      def mode_changed(_name, previous: nil); end
      def box_open(*_pieces, at: nil, color: nil); end
      def box_close(*_pieces, color: nil); end
      def queued(_text); end
      def input_injected(_text); end

      # --- Interactive: surface the approval, don't auto-deny -------------

      # Option 2 — approval-surfacing. In card mode WITH an approval handler
      # (wired by TaskTool), a child tool that needs approval is NOT silently
      # denied: we hand off to @approve, which flips the registry entry to
      # :needs_approval (surfacing it on the card + a parent note) and BLOCKS the
      # child thread on a per-entry Run::ApprovalGate until the user answers via
      # /agents <id> (or the 15-min bound auto-denies). The handler returns the
      # boolean decision, which we return so the child's tool proceeds or denies.
      #
      # Without a handler (legacy inline / foreground path) we keep the old
      # AUTO-DENY (false): a subagent there must never hang on a prompt no one can
      # answer.
      def confirm(question, scope: nil, **context)
        return @approve.call(question, scope: scope, **context) if @approve

        false
      end

      # No interactive clarification mid-delegation either.
      def ask(_prompt)
        nil
      end

      private

      # Asks the parent CLI to repaint the collapsed card block from the
      # registry's current snapshot. Best-effort and quiet: a repaint is cosmetic
      # and must never break the child's run. No-op when there's no parent CLI
      # (the registry still has the fresh data for the /agents drill-in).
      def repaint_cards
        @parent_ui.set_subagent_cards if @parent_ui.respond_to?(:set_subagent_cards)
      rescue StandardError
        nil
      end

      # Stable palette index for a name: CRC32 keeps it deterministic across
      # processes (Ruby's String#hash is salted per-run) and dependency-free.
      def color_index(name)
        Zlib.crc32(name) % PALETTE.size
      end

      # Emits one colored, indented, name-prefixed activity row.
      def row(text)
        return if text.nil? || text.to_s.strip.empty?

        @out.puts @pastel.public_send(@color, "#{INDENT}#{GLYPH} #{@agent_name} · #{text}")
      end

      # Dim variant for low-priority annotations (note/status/info).
      def dim_row(text)
        return if text.nil? || text.to_s.strip.empty?

        @out.puts @pastel.dim("#{INDENT}#{GLYPH} #{@agent_name} · #{first_line(text, 80)}")
      end

      # A compact metric for the finish row: prefer the tool's own metrics,
      # else a truncated preview of the output.
      def result_metric(result)
        return nil unless result

        metric = result.metrics if result.respond_to?(:metrics)
        return first_line(metric, 60) if metric && !metric.to_s.strip.empty?

        preview = result.truncated_preview if result.respond_to?(:truncated_preview)
        preview && !preview.to_s.strip.empty? ? first_line(preview, 60) : nil
      end

      # Short identifier piece from the tool arguments (path/pattern/command).
      def args_hint(arguments)
        return nil unless arguments.is_a?(Hash)

        %i[file_path path pattern command].each do |k|
          v = arguments[k] || arguments[k.to_s]
          return first_line(v, 60) if v && !v.to_s.strip.empty?
        end
        nil
      end

      # First NON-BLANK line, elided to +max+ — a multi-line ruby/shell command
      # often starts with a blank line, which would render an empty hint (#141).
      def first_line(text, max)
        first = text.to_s.each_line.map(&:strip).find { |l| !l.empty? }.to_s
        first.length > max ? "#{first[0, max - 1]}…" : first
      end
    end
  end
end
