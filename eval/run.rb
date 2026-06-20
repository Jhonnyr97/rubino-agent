# frozen_string_literal: true

# A/B evaluation harness for the rubino coding agent.
#
# Runs a fixed task suite N times with a feature TOGGLE OFF and ON, against a
# fresh isolated workspace per run, auto-checks success, captures cost metrics
# from rubino's stream-json output, and prints an A/B comparison table.
#
# The harness treats rubino as a BLACK BOX: it only runs the exe and reads its
# JSON output. It never mutates rubino's runtime code or the user's config.
#
# Usage:
#   ruby eval/run.rb --flag display.runtime_footer.enabled --on true --off false -n 2
#   ruby eval/run.rb --flag compression.enabled --on true --off false -n 3 --only fix_bug,add_method
#
# See eval/README.md.

require "optparse"
require "json"
require "time"
require "yaml"
require "fileutils"

ROOT = __dir__
require_relative "lib/eval/task"
require_relative "lib/eval/workspace"
require_relative "lib/eval/rubino_runner"
require_relative "lib/eval/checker"
require_relative "lib/eval/report"

module Eval
  # Orchestrates the full A/B run.
  class CLI
    DEFAULTS = {
      flag: "display.runtime_footer.enabled",
      on: "true",
      off: "false",
      n: 2,
      timeout: 300,
      tasks: File.join(ROOT, "tasks", "tasks.yml"),
      fixtures: File.join(ROOT, "fixtures"),
      results: File.join(ROOT, "results"),
      repo: File.expand_path("..", ROOT),
      source_home: File.expand_path("~/.rubino"),
      only: nil
    }.freeze

    def self.run(argv)
      new(parse(argv)).run
    end

    def self.parse(argv)
      opts = DEFAULTS.dup
      OptionParser.new do |o|
        o.banner = "Usage: ruby eval/run.rb --flag KEY [options]"
        o.on("--flag KEY", "Dotted config key to toggle (e.g. compression.enabled)") { |v| opts[:flag] = v }
        o.on("--on VALUE", "ON value (parsed as YAML scalar: true/false/3/\"x\")") { |v| opts[:on] = v }
        o.on("--off VALUE", "OFF value (default false)") { |v| opts[:off] = v }
        o.on("-n N", "--repeats N", Integer, "Repeats per task per arm (default 2)") { |v| opts[:n] = v }
        o.on("--only IDS", "Comma-separated task ids to run") { |v| opts[:only] = v.split(",").map(&:strip) }
        o.on("--timeout S", Integer, "Per-run wall-clock kill (default 300)") { |v| opts[:timeout] = v }
        o.on("--source-home DIR", "Real rubino home to clone config/.env from") { |v| opts[:source_home] = v }
        o.on("-h", "--help") do
          puts o
          exit 0
        end
      end.parse!(argv)
      opts
    end

    def initialize(opts)
      @opts = opts
      @tasks = TaskLoader.load(opts[:tasks], only: opts[:only])
      @runner = RubinoRunner.new(repo_dir: opts[:repo], timeout_s: opts[:timeout])
      @records = []
    end

    # ON/OFF values are parsed as YAML scalars so "true"->true, "3"->3, etc.
    def value_for(arm)
      YAML.safe_load(arm == "on" ? @opts[:on] : @opts[:off])
    end

    def run
      raise "no tasks selected" if @tasks.empty?

      banner
      @tasks.each { |task| run_task(task) }
      finish
    end

    private

    def banner
      puts "rubino A/B eval — flag=#{@opts[:flag]}  on=#{@opts[:on]}  off=#{@opts[:off]}  " \
           "N=#{@opts[:n]}  tasks=#{@tasks.map(&:id).join(",")}"
    end

    def run_task(task)
      puts "\n## #{task.id} (#{task.kind})"
      Report::ARMS.each do |arm|
        @opts[:n].times { |i| run_once(task, arm, i) }
      end
    end

    def run_once(task, arm, repeat)
      ws = Workspace.new(source_home: @opts[:source_home], fixtures_dir: @opts[:fixtures])
      ws.prepare_config!(flag_path: @opts[:flag], value: value_for(arm))
      ws.stage_fixture!(task.fixture)

      metrics = @runner.run(prompt: task.prompt, workspace: ws)
      check = Checker.run(task.check, ws.workdir)
      passed = metrics.ok && check.passed

      @records << {
        task: task.id, kind: task.kind.to_s, arm: arm, repeat: repeat,
        passed: passed, metrics: metrics, check_output: check.output
      }
      status = passed ? "PASS" : "FAIL"
      detail = metrics.ok ? "" : " (run-error: #{metrics.error})"
      printf("  [%-3s #%d] %-4s  %4.1fs  turns=%d tools=%d out_tok=%d%s\n",
             arm, repeat + 1, status, metrics.wall_clock_s,
             metrics.num_turns, metrics.tool_calls, metrics.output_tokens, detail)
    ensure
      ws&.cleanup
    end

    def finish
      summary = Report.summarize(@records)
      puts Report.render(
        summary, flag: @opts[:flag],
                 value_off: value_for("off"), value_on: value_for("on"), n: @opts[:n]
      )
      path = save_results(summary)
      puts "raw results: #{path}"
    end

    def save_results(summary)
      FileUtils.mkdir_p(@opts[:results])
      stamp = Time.now.strftime("%Y%m%dT%H%M%S")
      path = File.join(@opts[:results], "#{stamp}.json")
      File.write(path, JSON.pretty_generate(
                         flag: @opts[:flag], on: @opts[:on], off: @opts[:off],
                         n: @opts[:n], generated_at: Time.now.iso8601,
                         summary: summary,
                         runs: @records.map { |r| serialize_record(r) }
                       ))
      path
    end

    def serialize_record(record)
      record.merge(metrics: record[:metrics].to_h)
    end
  end
end

Eval::CLI.run(ARGV) if $0 == __FILE__
