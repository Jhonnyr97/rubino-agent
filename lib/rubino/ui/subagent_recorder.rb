# frozen_string_literal: true

require "delegate"

module Rubino
  module UI
    # A thin UI decorator wrapping a background subagent's OWN UI::CLI. It records
    # the BackgroundTasks registry COUNTERS a subagent feeds — tool_count /
    # last_activity / activity_log / output_tail — then DELEGATES every UI call to
    # the wrapped CLI, which renders the subagent's live activity exactly like the
    # main agent (the focus-gate decides if it actually paints, via the CLI's
    # origin tag).
    #
    # Why a decorator and not the CLI itself: those counters feed surfaces OFF the
    # screen — probe_tool, the /agents drill-in, and the ambient collapsed cards —
    # so they must be updated even when the sub isn't focused (its frames are
    # dropped, but its registry entry must stay live). Recording them here keeps
    # UI::CLI free of any BackgroundTasks coupling: the CLI is a pure renderer, one
    # instance per agent, and this wrapper is the per-RUN seam the task tool adds.
    #
    # Wired by Tools::TaskTool#nested_ui_for around the per-sub CLI. SimpleDelegator
    # forwards info/error/stream/box_open/confirm/select/… to the CLI untouched; we
    # override only the three tool events that carry the registry counters. The
    # record calls take the registry mutex (we run on the CHILD thread) and are
    # best-effort — a registry hiccup must never break the child's run.
    class SubagentRecorder < SimpleDelegator
      # @param cli [UI::CLI] the per-subagent renderer to delegate display to.
      # @param entry_id [String] the BackgroundTasks entry this run feeds.
      def initialize(cli, entry_id:)
        super(cli)
        @entry_id = entry_id
      end

      # Bump the tool counter + last-activity string the cards/list/drill-in show,
      # THEN let the CLI render the tool box as usual.
      def tool_started(name, arguments: nil, at: nil, call_id: nil)
        hint     = args_hint(arguments)
        activity = hint ? "#{name} #{hint}" : name.to_s
        record { Tools::BackgroundTasks.instance.record_tool_started(@entry_id, activity) }
        super
      end

      # Append the terse finish line to the entry's activity ring (the drill-in
      # tails it), THEN delegate the rendered tool-done box to the CLI.
      def tool_finished(name, result: nil)
        record { Tools::BackgroundTasks.instance.record_tool_finished(@entry_id, finish_line(name, result)) }
        super
      end

      # Append the streamed chunk to the entry's bounded output tail (the live
      # output: block the /agents <id> watch tails), THEN delegate to the CLI.
      def tool_chunk(name, chunk, kind: :plain)
        record { Tools::BackgroundTasks.instance.record_tool_output(@entry_id, chunk) }
        super
      end

      private

      # A registry update is bookkeeping for off-screen surfaces — never let it
      # break the child's run (the wrapped CLI render still happens regardless).
      def record
        yield
      rescue StandardError
        nil
      end

      # The terse `✓ name · metric` / `✗ name · metric` line the activity ring
      # keeps (ported 1:1 from the old SubagentView so the drill-in reads the same).
      def finish_line(name, result)
        failed = result.respond_to?(:success?) && !result.success?
        icon   = failed ? "✗" : "✓"
        suffix = result_metric(result)
        suffix ? "#{icon} #{name} · #{suffix}" : "#{icon} #{name}"
      end

      # A compact metric for the finish line: prefer the tool's own metrics, else
      # a truncated preview of the output.
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

      # First NON-BLANK line, elided to +max+.
      def first_line(text, max)
        Rubino::Util::Output.first_line(text, max)
      end
    end
  end
end
