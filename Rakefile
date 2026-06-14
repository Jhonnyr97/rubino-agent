# frozen_string_literal: true

require "bundler/gem_tasks"
require "rspec/core/rake_task"

RSpec::Core::RakeTask.new(:spec)

task default: :spec

# Parallel test execution across CPU cores via the `parallel_tests` gem.
#
#   rake parallel:spec            # auto: one worker per core
#   rake parallel:spec[4]         # force 4 workers
#
# Each worker is its own process with a distinct TEST_ENV_NUMBER, so the
# per-process isolation already baked into spec/spec_helper.rb (RUBINO_HOME,
# document fixtures, example-status file) keeps workers from colliding.
# SimpleCov is skipped in parallel (workers would race the resultset); run the
# plain sequential `rake spec` / `bundle exec rspec` for a coverage report.
#
# We balance by RECORDED RUNTIME rather than file count: one example
# (agent_e2e error-retry) dominates wall-clock, so runtime grouping keeps it
# from gating an otherwise-idle worker. `--runtime-log` makes every run WRITE
# the timing file, and we only ASK parallel_tests to group by it once it
# exists (the first run grades on filesize, then logs runtimes for the next).
namespace :parallel do
  RUNTIME_LOG = "tmp/parallel_runtime_rspec.log"

  desc "Run the RSpec suite in parallel across CPU cores (rake parallel:spec[N])"
  task :spec, [:count] do |_t, args|
    require "fileutils"
    # parallel_tests --runtime-log won't create the dir; without it the first
    # run can't record timings and every run falls back to filesize grouping.
    FileUtils.mkdir_p(File.dirname(RUNTIME_LOG))
    count = args[:count]
    cmd = ["bundle", "exec", "parallel_rspec"]
    cmd += ["-n", count.to_s] if count && !count.empty?
    cmd += ["--runtime-log", RUNTIME_LOG]
    cmd += ["--group-by", "runtime"] if File.exist?(RUNTIME_LOG)
    cmd += ["--", "spec"]
    sh(*cmd)
  end
end
