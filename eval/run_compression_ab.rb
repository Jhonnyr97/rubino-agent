# frozen_string_literal: true

# Compression A/B driver (#533 validation, on top of the #534 harness).
#
# This is a HARNESS ADDITION, not a change to rubino runtime code. It reuses the
# eval/ libs (Workspace, Checker, TaskLoader, Report) but uses its own runner so
# it can ALSO capture rubino's STDERR — where, in one-shot stream-json mode, the
# structured logger is pinned (chat_command#redirect_logger_to_stderr). The
# compression telemetry events (compression.applied / .drill_in / .failed) land
# there, and the stock eval/run.rb discards stderr.
#
# It prints the same A/B table eval/run.rb does PLUS a compression-signals block
# for the ON arm: reads compressed, total tokens saved, and the drill-in rate
# (drill_in count / applied count — the "skeleton hid what was needed" DEGRADE
# signal).
#
# Usage:
#   ruby eval/run_compression_ab.rb -n 3 --only code_chat_command,code_agent_loop

require "optparse"
require "json"
require "time"
require "yaml"
require "fileutils"
require "open3"

ROOT = __dir__
require_relative "lib/eval/task"
require_relative "lib/eval/workspace"
require_relative "lib/eval/checker"
require_relative "lib/eval/report"

module Eval
  # Runner variant that captures stderr and parses compression telemetry.
  class TelemetryRunner
    # input_tokens / cache_read_input_tokens are carried (always 0 on MiniMax,
    # which reports neither) purely so eval/lib/eval/report.rb — which tallies
    # those columns — runs unchanged against these records.
    RunResult = Struct.new(
      :ok, :result_text, :num_turns, :tool_calls, :wall_clock_s,
      :output_tokens, :input_tokens, :cache_read_input_tokens,
      :error, :compression_events,
      keyword_init: true
    )

    def initialize(repo_dir:, timeout_s: 300)
      @gemfile = File.join(repo_dir, "Gemfile")
      @exe = File.join(repo_dir, "exe", "rubino")
      @timeout_s = timeout_s
    end

    def run(prompt:, workspace:)
      cmd = [
        "bundle", "exec", "--gemfile=#{@gemfile}", @exe, "chat",
        "--output-format", "stream-json", "--yolo", "--new",
        "--max-turns", "20", "-q", prompt
      ]
      env = { "RUBINO_HOME" => workspace.home }

      started = clock
      out, err, status, timed_out = capture(cmd, env, workspace.workdir)
      wall = clock - started

      parse(out, err, status, timed_out, wall, workspace.workdir)
    end

    private

    def clock = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    def capture(cmd, env, chdir)
      out = +""
      err = +""
      timed_out = false
      status = nil
      Open3.popen3(env, *cmd, chdir: chdir) do |stdin, stdout, stderr, wait|
        stdin.close
        deadline = clock + @timeout_s
        readers = [stdout, stderr]
        until readers.empty?
          ready, = IO.select(readers, nil, nil, 1)
          if clock > deadline
            timed_out = true
            begin
              Process.kill("KILL", wait.pid)
            rescue StandardError
              nil
            end
            break
          end
          next unless ready

          ready.each do |io|
            chunk = io.read_nonblock(16_384, exception: false)
            if chunk == :wait_readable then next
            elsif chunk.nil? then readers.delete(io)
            else (io == stdout ? out : err) << chunk
            end
          end
        end
        status = wait.value
      end
      [out, err, status, timed_out]
    end

    # Pull every compression.* structured line out of stderr.
    def compression_events(err)
      err.each_line.filter_map do |line|
        f = JSON.parse(line)
        next nil unless f["event"].to_s.start_with?("compression.")

        f
      rescue JSON::ParserError
        nil
      end
    end

    def parse(out, err, status, timed_out, wall, workdir)
      frames = out.each_line.filter_map do |line|
        JSON.parse(line)
      rescue JSON::ParserError
        nil
      end
      result = frames.reverse.find { |f| f["type"] == "result" }
      tool_calls = frames.sum do |f|
        next 0 unless f["type"] == "assistant"

        Array(f.dig("message", "content")).count { |b| b["type"] == "tool_use" }
      end
      events = compression_events(err)

      if timed_out
        return RunResult.new(ok: false, result_text: "", num_turns: 0,
                             tool_calls: tool_calls, wall_clock_s: wall.round(3),
                             output_tokens: 0, error: "timeout", compression_events: events)
      end
      unless result
        return RunResult.new(ok: false, result_text: "", num_turns: 0,
                             tool_calls: tool_calls, wall_clock_s: wall.round(3),
                             output_tokens: 0,
                             error: "no result frame (exit #{status&.exitstatus})",
                             compression_events: events)
      end

      text = result["result"].to_s
      File.write(File.join(workdir, "RESULT.txt"), text)
      usage = result["usage"] || {}
      RunResult.new(
        ok: !result["is_error"], result_text: text,
        num_turns: result["num_turns"].to_i, tool_calls: tool_calls,
        wall_clock_s: wall.round(3), output_tokens: usage["output_tokens"].to_i,
        input_tokens: usage["input_tokens"].to_i,
        cache_read_input_tokens: usage["cache_read_input_tokens"].to_i,
        error: result.dig("error", "message"), compression_events: events
      )
    end
  end

  # Orchestrates the compression A/B + telemetry aggregation.
  class CompressionAB
    FLAG = "tool_output_compression.enabled"

    def self.run(argv)
      opts = { n: 3, only: nil, timeout: 300,
               repo: File.expand_path("..", ROOT),
               source_home: File.expand_path("~/.rubino"),
               fixtures: File.join(ROOT, "fixtures"),
               tasks: File.join(ROOT, "tasks", "tasks.yml"),
               results: File.join(ROOT, "results") }
      OptionParser.new do |o|
        o.on("-n N", Integer) { |v| opts[:n] = v }
        o.on("--only IDS") { |v| opts[:only] = v.split(",").map(&:strip) }
        o.on("--timeout S", Integer) { |v| opts[:timeout] = v }
        # Point the isolated RUBINO_HOME at a config that reports REAL input
        # tokens (e.g. an oMLX home) — MiniMax reports neither input nor cache.
        o.on("--source-home DIR") { |v| opts[:source_home] = File.expand_path(v) }
        o.on("--tasks FILE") { |v| opts[:tasks] = File.expand_path(v) }
      end.parse!(argv)
      new(opts).run
    end

    def initialize(opts)
      @opts = opts
      @tasks = TaskLoader.load(opts[:tasks], only: opts[:only])
      @runner = TelemetryRunner.new(repo_dir: opts[:repo], timeout_s: opts[:timeout])
      @records = []
      @events = { "on" => [], "off" => [] }
    end

    def run
      raise "no tasks selected" if @tasks.empty?

      puts "compression A/B — flag=#{FLAG}  N=#{@opts[:n]}  tasks=#{@tasks.map(&:id).join(",")}"
      @tasks.each { |t| run_task(t) }
      report
    end

    private

    def run_task(task)
      puts "\n## #{task.id} (#{task.kind})"
      Report::ARMS.each do |arm|
        @opts[:n].times { |i| run_once(task, arm, i) }
      end
    end

    def run_once(task, arm, repeat)
      ws = Workspace.new(source_home: @opts[:source_home], fixtures_dir: @opts[:fixtures])
      ws.prepare_config!(flag_path: FLAG, value: (arm == "on"))
      # Match a REAL opted-in install. The master flag alone leaves the log
      # channel OFF: `setup` writes BOTH tool_output_compression.enabled AND
      # .logs.enabled (setup_command#maybe_offer_log_compression), and the
      # config default for logs.enabled is false. code/diff/json need only the
      # master flag (their defaults — strategy=skeleton etc. — merge in at
      # runtime), so the master toggle covers them; logs needs this explicit set.
      enable_log_channel!(ws) if arm == "on"
      ws.stage_fixture!(task.fixture)

      m = @runner.run(prompt: task.prompt, workspace: ws)
      check = Checker.run(task.check, ws.workdir)
      passed = m.ok && check.passed
      @events[arm].concat(m.compression_events)
      @records << { task: task.id, arm: arm, repeat: repeat, passed: passed, metrics: m }

      applied = m.compression_events.count { |e| e["event"] == "compression.applied" }
      drill = m.compression_events.count { |e| e["event"] == "compression.drill_in" }
      printf("  [%-3s #%d] %-4s  %5.1fs  turns=%d tools=%d in_tok=%d out_tok=%d  cmp(applied=%d drill=%d)%s\n",
             arm, repeat + 1, passed ? "PASS" : "FAIL", m.wall_clock_s, m.num_turns,
             m.tool_calls, m.input_tokens, m.output_tokens, applied, drill,
             m.ok ? "" : " (#{m.error})")
    ensure
      ws&.cleanup
    end

    def report
      summary = Report.summarize(
        @records.map { |r| r.merge(kind: "find", check_output: "") }
      )
      puts Report.render(summary, flag: FLAG, value_off: false, value_on: true, n: @opts[:n])

      print_per_task
      signals = compression_signals
      print_signals(signals)
      puts "\nraw results: #{save_results(summary, signals)}"
    end

    # Per-task ON vs OFF: the headline INPUT-token mean (trustworthy on oMLX),
    # success, mean tool-calls, mean wall-clock. This is where the per-channel
    # story lives (a code/log/diff/json task each shows its own delta).
    def print_per_task
      puts "\n=== per-task (ON vs OFF) — mean input tokens is the headline ==="
      printf("  %-18s %-4s %7s %7s %8s   %6s %6s   %5s %5s   %5s %5s\n",
             "task", "", "succ%", "succ%", "Δin%",
             "in", "in", "tool", "tool", "wall", "wall")
      printf("  %-18s %-4s %7s %7s %8s   %6s %6s   %5s %5s   %5s %5s\n",
             "", "", "OFF", "ON", "(on-off)", "OFF", "ON", "OFF", "ON", "OFF", "ON")
      @records.map { |r| r[:task] }.uniq.each do |task|
        off = @records.select { |r| r[:task] == task && r[:arm] == "off" }
        on  = @records.select { |r| r[:task] == task && r[:arm] == "on" }
        in_off = mean(off) { |r| r[:metrics].input_tokens }
        in_on  = mean(on)  { |r| r[:metrics].input_tokens }
        din = in_off.zero? ? 0.0 : (in_on - in_off) / in_off * 100
        printf("  %-18s %-4s %6.0f%% %6.0f%% %+7.1f%%   %6.0f %6.0f   %5.1f %5.1f   %5.1f %5.1f\n",
               task, "", succ(off) * 100, succ(on) * 100, din,
               in_off, in_on,
               mean(off) { |r| r[:metrics].tool_calls }, mean(on) { |r| r[:metrics].tool_calls },
               mean(off) { |r| r[:metrics].wall_clock_s }, mean(on) { |r| r[:metrics].wall_clock_s })
      end
    end

    # Turn the log channel on in the workspace config the same way `setup` does
    # for a real opt-in (the master flag alone leaves logs.enabled=false).
    def enable_log_channel!(ws)
      path = File.join(ws.home, "config.yml")
      cfg = YAML.safe_load_file(path, permitted_classes: [Symbol]) || {}
      cfg["tool_output_compression"] ||= {}
      cfg["tool_output_compression"]["logs"] ||= {}
      cfg["tool_output_compression"]["logs"]["enabled"] = true
      File.write(path, YAML.dump(cfg))
    end

    def mean(records)
      return 0.0 if records.empty?

      records.sum { |r| yield(r).to_f } / records.size
    end

    def succ(records)
      return 0.0 if records.empty?

      records.count { |r| r[:passed] }.fdiv(records.size)
    end

    # Aggregate the ON-arm telemetry into the benefit (tokens saved) and the
    # DEGRADE signal (drill-in rate = re-reads of an elided body / compressions).
    def compression_signals
      on = @events["on"]
      applied = on.select { |e| e["event"] == "compression.applied" }
      drill = on.select { |e| e["event"] == "compression.drill_in" }
      failed = on.select { |e| e["event"] == "compression.failed" }
      by_type = applied.group_by { |e| e["content_type"] }.transform_values do |evs|
        { count: evs.size, saved: evs.sum { |e| e["saved_tokens_est"].to_i } }
      end
      { on: on, applied: applied.size, drill_in: drill.size, failed: failed.size,
        tokens_saved: applied.sum { |e| e["saved_tokens_est"].to_i },
        drill_in_rate: applied.empty? ? 0.0 : drill.size.fdiv(applied.size),
        by_type: by_type,
        off_arm_applied: @events["off"].count { |e| e["event"] == "compression.applied" } }
    end

    def print_signals(sig)
      puts "\n=== compression signals (ON arm) ==="
      puts "reads compressed (applied): #{sig[:applied]}"
      puts "total tokens saved (est):   #{sig[:tokens_saved]}"
      puts "drill-in events:            #{sig[:drill_in]}"
      puts "drill-in rate:              #{(sig[:drill_in_rate] * 100).round(1)}%  (drill_in / applied)"
      puts "compression failures:       #{sig[:failed]}"
      puts "(sanity: OFF arm applied=#{sig[:off_arm_applied]} — should be 0)"
      puts "by content_type (which strategy fired):"
      sig[:by_type].each do |type, agg|
        puts format("  %-6s applied=%-3d saved_est=%d tok", type, agg[:count], agg[:saved])
      end
    end

    def save_results(summary, signals)
      FileUtils.mkdir_p(@opts[:results])
      path = File.join(@opts[:results], "compression_ab_#{Time.now.strftime("%Y%m%dT%H%M%S")}.json")
      File.write(path, JSON.pretty_generate(
                         flag: FLAG, n: @opts[:n], generated_at: Time.now.iso8601,
                         summary: summary,
                         compression: signals.except(:on),
                         events_on: signals[:on],
                         runs: @records.map { |r| serialize_run(r) }
                       ))
      path
    end

    def serialize_run(record)
      m = record[:metrics]
      { task: record[:task], arm: record[:arm], repeat: record[:repeat],
        passed: record[:passed], wall_clock_s: m.wall_clock_s,
        num_turns: m.num_turns, tool_calls: m.tool_calls,
        input_tokens: m.input_tokens, output_tokens: m.output_tokens,
        cache_read_input_tokens: m.cache_read_input_tokens,
        compression_events: m.compression_events.map { |e| e["event"] } }
    end
  end
end

Eval::CompressionAB.run(ARGV) if $0 == __FILE__
