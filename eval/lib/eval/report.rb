# frozen_string_literal: true

module Eval
  # Aggregates raw per-run records into per-arm summaries and prints the A/B
  # comparison table.
  #
  # A "record" is a Hash: { task:, kind:, arm: "off"|"on", repeat:, passed:,
  # metrics: RunResult }.
  module Report
    module_function

    ARMS = %w[off on].freeze

    # --- aggregation ---------------------------------------------------------

    def summarize(records)
      ARMS.to_h do |arm|
        arm_records = records.select { |r| r[:arm] == arm }
        [arm, arm_summary(arm_records)]
      end
    end

    def arm_summary(records)
      return empty_summary if records.empty?

      passed = records.count { |r| r[:passed] }
      {
        runs: records.size,
        success_rate: passed.to_f / records.size,
        input_tokens: stats(records) { |r| r[:metrics].input_tokens },
        output_tokens: stats(records) { |r| r[:metrics].output_tokens },
        cache_read: stats(records) { |r| r[:metrics].cache_read_input_tokens },
        tool_calls: stats(records) { |r| r[:metrics].tool_calls },
        num_turns: stats(records) { |r| r[:metrics].num_turns },
        wall_clock_s: stats(records) { |r| r[:metrics].wall_clock_s }
      }
    end

    def empty_summary
      { runs: 0, success_rate: 0.0 }
    end

    def stats(records)
      values = records.map { |r| yield(r).to_f }
      mean = values.sum / values.size
      var  = values.sum { |v| (v - mean)**2 } / values.size
      { mean: mean, min: values.min, max: values.max, stddev: Math.sqrt(var) }
    end

    # --- rendering -----------------------------------------------------------

    METRIC_ROWS = [
      [:success_rate, "success rate", :rate, :higher],
      [:input_tokens, "mean input tok", :num, :lower],
      [:cache_read, "mean cache_read", :num, :higher],
      [:output_tokens, "mean output tok", :num, :lower],
      [:tool_calls, "mean tool-calls", :num, :lower],
      [:num_turns, "mean model-calls", :num, :lower],
      [:wall_clock_s, "mean wall-clock s", :num, :lower]
    ].freeze

    def render(summary, flag:, value_off:, value_on:, n:)
      off = summary["off"]
      on  = summary["on"]
      lines = []
      lines << ""
      lines << "A/B EVAL  —  flag: #{flag}"
      lines << "  OFF = #{value_off.inspect}   ON = #{value_on.inspect}   N=#{n}/task/arm"
      lines << "  runs/arm: OFF #{off[:runs]}  ON #{on[:runs]}"
      lines << ""
      header = "  metric                        OFF             ON     Δ (on-off)   verdict"
      lines << header
      lines << "  #{"-" * (header.length - 2)}"

      METRIC_ROWS.each do |key, label, fmt, better|
        next unless off[key] && on[key]

        o = key == :success_rate ? off[key] : off[key][:mean]
        n_ = key == :success_rate ? on[key] : on[key][:mean]
        lines << format(
          "  %-18s %14s %14s %14s   %s",
          label, fmt_val(o, fmt), fmt_val(n_, fmt),
          fmt_delta(n_ - o, fmt), verdict(o, n_, better)
        )
      end
      lines << ""
      lines << "  spread (min/max · stddev), per arm:"
      lines.concat(spread_lines(off, on))
      lines << ""
      lines.join("\n")
    end

    def spread_lines(off, on)
      %i[tool_calls num_turns wall_clock_s output_tokens].filter_map do |key|
        next unless off[key] && on[key]

        format(
          "    %-16s OFF %.1f/%.1f σ%.1f    ON %.1f/%.1f σ%.1f",
          key, off[key][:min], off[key][:max], off[key][:stddev],
          on[key][:min], on[key][:max], on[key][:stddev]
        )
      end
    end

    def fmt_val(value, fmt)
      case fmt
      when :rate then format("%.0f%%", value * 100)
      else format("%.1f", value)
      end
    end

    def fmt_delta(delta, fmt)
      sign = delta.positive? ? "+" : ""
      case fmt
      when :rate then "#{sign}#{format("%.0f", delta * 100)}pp"
      else "#{sign}#{format("%.1f", delta)}"
      end
    end

    # One-line verdict: did ON move the metric in the desired direction?
    def verdict(off, on, better)
      return "=" if (on - off).abs < 1e-9

      improved = better == :higher ? on > off : on < off
      improved ? "ON better" : "ON worse"
    end
  end
end
