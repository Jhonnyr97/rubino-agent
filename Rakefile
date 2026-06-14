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
# We balance by RECORDED RUNTIME (--group-by runtime) rather than file count:
# one example (agent_e2e error-retry) dominates wall-clock, so runtime grouping
# keeps it from gating an otherwise-idle worker once a timing log exists. The
# first run falls back to filesize grouping and writes the runtime log used by
# subsequent runs.
namespace :parallel do
  desc "Run the RSpec suite in parallel across CPU cores (rake parallel:spec[N])"
  task :spec, [:count] do |_t, args|
    count = args[:count]
    cmd = ["bundle", "exec", "parallel_rspec"]
    cmd += ["-n", count.to_s] if count && !count.empty?
    cmd += ["--group-by", "runtime", "--", "spec"]
    sh(*cmd)
  end
end
