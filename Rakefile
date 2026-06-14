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
# Balancing: we use parallel_tests' default **filesize** grouping rather than
# runtime grouping. Runtime grouping (`--group-by runtime`) is strict — it
# aborts with RuntimeLogTooSmallError whenever the recorded log is missing an
# entry for any current spec file (i.e. the first run after ANY new spec is
# added), which makes the entrypoint brittle. The wall-clock floor here is a
# single ~70s example (agent_e2e error-retry) that cannot be split across
# workers regardless of grouping, so filesize grouping already lands the
# longest worker on essentially that floor while staying deterministic and
# never breaking on a freshly-added spec.
namespace :parallel do
  desc "Run the RSpec suite in parallel across CPU cores (rake parallel:spec[N])"
  task :spec, [:count] do |_t, args|
    count = args[:count]
    cmd = ["bundle", "exec", "parallel_rspec"]
    cmd += ["-n", count.to_s] if count && !count.empty?
    cmd += ["--", "spec"]
    sh(*cmd)
  end
end
