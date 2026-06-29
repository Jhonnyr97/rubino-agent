# frozen_string_literal: true

# Foreground-`&` hang regression. A model that starts a long-lived process in the
# FOREGROUND with a trailing `&` (e.g. `ruby server.rb &`) leaves a detached
# child holding the merged stdout/stderr pipe: the direct shell exits at once,
# but the pipe never reaches EOF, so the old drain (`output_thr.value`) blocked
# the whole turn until the process happened to die (or the 120s timeout). The
# tool now bounds the post-exit drain (DETACHED_DRAIN_GRACE) and killpg's the
# stray group — the Codex/Goose pattern — returning promptly with a hint.
RSpec.describe Rubino::Tools::ShellTool do
  subject(:tool) { described_class.new }

  def payload(result) = result.is_a?(Hash) ? result[:output] : result

  describe "#call with a detached background child holding the pipe" do
    it "returns within the drain grace instead of hanging on the daemon's pipe" do
      # `sleep 20 &` inherits the output pipe and would hold it ~20s; `echo`
      # prints then the shell exits immediately. Without the bounded drain the
      # call blocks ~20s (the sleep) — or the 120s timeout. With it, ~grace.
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      result  = tool.call("command" => "echo started_marker; sleep 20 &")
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

      # Decisively faster than the 20s daemon and the 120s timeout, but allow
      # the 2s grace plus scheduling slack.
      expect(elapsed).to be < 8
      expect(payload(result)).to include("started_marker")
    end

    it "tells the model to use run_in_background instead of a trailing `&`" do
      result = tool.call("command" => "echo hi; sleep 20 &")
      expect(payload(result)).to include("run_in_background")
    end

    it "reports the direct command's own exit status (the `&` shell exits 0)" do
      result = tool.call("command" => "echo hi; sleep 20 &")
      # Foreground success → metrics read "exit 0 · …"; not a timeout/cancel.
      expect(result).to be_a(Hash)
      expect(result[:metrics]).to match(/\Aexit 0 · /)
    end

    it "does NOT add the note for a normal fast command (no detached writer)" do
      result = tool.call("command" => "echo plain")
      expect(payload(result)).to include("plain")
      expect(payload(result)).not_to include("run_in_background")
    end
  end
end
