# frozen_string_literal: true

require "json"
require "open3"

module Eval
  # Runs rubino as a BLACK BOX in a prepared workspace and extracts the metrics
  # the A/B report needs from its structured (stream-json) output.
  #
  # What we parse, and from WHERE (verified against this branch's emitter,
  # lib/rubino/output/result_serializer.rb):
  #   * final result text, num_turns, duration_ms (rubino's own turn clock),
  #     usage{input/output/cache}, total_cost_usd, model
  #       → from the terminal `{type:"result"}` frame.
  #   * tool_calls — counted by tallying `tool_use` blocks across the
  #     `{type:"assistant"}` frames (a round-trip proxy). The result frame's
  #     num_turns counts MODEL CALLS, which is a second, coarser proxy.
  #   * wall_clock_s — measured by THIS runner (Process.clock_gettime), the
  #     true end-to-end cost including process spawn.
  #
  # Honest gaps on the MiniMax backend: it does NOT report input or cache
  # tokens, so usage.input_tokens / cache_read_input_tokens come back 0 and
  # total_cost_usd is null. The report surfaces whatever the provider gives and
  # leans on output_tokens / num_turns / tool_calls / wall_clock as the reliable
  # cost signals.
  RunResult = Struct.new(
    :ok, :result_text, :num_turns, :tool_calls, :duration_ms, :wall_clock_s,
    :input_tokens, :output_tokens, :cache_read_input_tokens,
    :cache_creation_input_tokens, :total_cost_usd, :model, :error,
    keyword_init: true
  )

  # Spawns rubino and turns its stream-json into a RunResult (see above).
  class RubinoRunner
    # repo_dir   — the rubino-agent checkout (for --gemfile + exe path).
    # timeout_s  — hard wall-clock kill for a single run.
    def initialize(repo_dir:, timeout_s: 300)
      @repo_dir  = repo_dir
      @gemfile   = File.join(repo_dir, "Gemfile")
      @exe       = File.join(repo_dir, "exe", "rubino")
      @timeout_s = timeout_s
    end

    # Runs one prompt in workspace.workdir under workspace.home.
    # Writes the final answer to RESULT.txt in the workdir (for find-task checks).
    def run(prompt:, workspace:)
      cmd = [
        "bundle", "exec", "--gemfile=#{@gemfile}", @exe, "chat",
        "--output-format", "stream-json", "--yolo", "--new",
        "--max-turns", "20", "-q", prompt
      ]
      env = { "RUBINO_HOME" => workspace.home }

      started = clock
      stdout, _stderr, status, timed_out = capture(cmd, env, workspace.workdir)
      wall = clock - started

      parse(stdout, status, timed_out, wall, workspace.workdir)
    end

    private

    def clock = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    # Runs the command with a timeout, returning [stdout, stderr, status, timed_out].
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
            if chunk == :wait_readable
              next
            elsif chunk.nil?
              readers.delete(io)
            else
              (io == stdout ? out : err) << chunk
            end
          end
        end
        status = wait.value
      end
      [out, err, status, timed_out]
    end

    def parse(stdout, status, timed_out, wall, workdir)
      frames = stdout.each_line.filter_map do |line|
        JSON.parse(line)
      rescue JSON::ParserError
        nil
      end

      result = frames.reverse.find { |f| f["type"] == "result" }
      tool_calls = count_tool_calls(frames)

      return error_result(wall, tool_calls, "timeout after #{@timeout_s}s") if timed_out

      unless result
        msg = "no result frame (exit #{status&.exitstatus})"
        return error_result(wall, tool_calls, msg)
      end

      text = result["result"].to_s
      File.write(File.join(workdir, "RESULT.txt"), text)
      usage = result["usage"] || {}

      RunResult.new(
        ok: !result["is_error"],
        result_text: text,
        num_turns: result["num_turns"].to_i,
        tool_calls: tool_calls,
        duration_ms: result["duration_ms"].to_i,
        wall_clock_s: wall.round(3),
        input_tokens: usage["input_tokens"].to_i,
        output_tokens: usage["output_tokens"].to_i,
        cache_read_input_tokens: usage["cache_read_input_tokens"].to_i,
        cache_creation_input_tokens: usage["cache_creation_input_tokens"].to_i,
        total_cost_usd: result["total_cost_usd"],
        model: result["model"],
        error: result.dig("error", "message")
      )
    end

    def count_tool_calls(frames)
      frames.sum do |f|
        next 0 unless f["type"] == "assistant"

        Array(f.dig("message", "content")).count { |b| b["type"] == "tool_use" }
      end
    end

    def error_result(wall, tool_calls, message)
      RunResult.new(
        ok: false, result_text: "", num_turns: 0, tool_calls: tool_calls,
        duration_ms: 0, wall_clock_s: wall.round(3), input_tokens: 0,
        output_tokens: 0, cache_read_input_tokens: 0,
        cache_creation_input_tokens: 0, total_cost_usd: nil, model: nil,
        error: message
      )
    end
  end
end
