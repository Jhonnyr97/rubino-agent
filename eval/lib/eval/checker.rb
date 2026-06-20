# frozen_string_literal: true

require "open3"

module Eval
  # Runs a task's success-check shell command in the workspace. Exit 0 = PASS.
  # The command sees the post-run workspace (edited files, plus RESULT.txt
  # holding the agent's final answer for find-tasks).
  module Checker
    module_function

    CheckResult = Struct.new(:passed, :output, keyword_init: true)

    def run(check, workdir)
      out, status = Open3.capture2e(check, chdir: workdir)
      CheckResult.new(passed: status.success?, output: out.strip)
    end
  end
end
