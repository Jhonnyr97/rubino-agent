# frozen_string_literal: true

require "tmpdir"
require "fileutils"

# Issue #101: a structured test-runner so the model reads pass/fail counts and
# the failing examples instead of driving raw `shell` and parsing bundler/
# toolchain backtraces. These specs build tiny temp workspaces (no Gemfile, so
# the tool uses the bare runner already on PATH) and assert on the STRUCTURED
# result, not just the text.
RSpec.describe Rubino::Tools::TestTool do
  subject(:tool) { described_class.new }

  # Point the tool's workspace resolution (terminal.cwd) at the temp project.
  def in_workspace(dir)
    cfg = test_configuration("terminal" => { "cwd" => dir })
    allow(Rubino).to receive(:configuration).and_return(cfg)
    yield
  end

  it "has name 'run_tests' and :medium risk" do
    expect(tool.name).to eq("run_tests")
    expect(tool.risk_level).to eq(:medium)
  end

  it "reports no test setup for an empty workspace" do
    Dir.mktmpdir do |dir|
      in_workspace(dir) do
        res = tool.call({})
        expect(res[:error_code]).to eq(:no_test_setup)
        expect(res[:output]).to include("no test setup detected")
      end
    end
  end

  context "with a passing RSpec suite" do
    around do |example|
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "spec"))
        File.write(File.join(dir, ".rspec"), "--no-color\n")
        File.write(File.join(dir, "spec", "math_spec.rb"), <<~SPEC)
          RSpec.describe "math" do
            it "adds" do
              expect(1 + 1).to eq(2)
            end
            it "multiplies" do
              expect(2 * 3).to eq(6)
            end
          end
        SPEC
        @dir = dir
        example.run
      end
    end

    it "detects rspec and returns a structured success with 0 failures" do
      in_workspace(@dir) do
        res = tool.call({})
        expect(res[:framework]).to eq("rspec")
        expect(res[:command]).to eq("rspec") # no Gemfile -> bare runner
        expect(res[:ran]).to be(true)
        expect(res[:exit_code]).to eq(0)
        expect(res[:examples]).to eq(2)
        expect(res[:failures]).to eq(0)
        expect(res[:failing]).to be_empty
        expect(res[:error_code]).to be_nil
        expect(res[:output]).to include("outcome:   passed")
      end
    end
  end

  context "with a failing RSpec example" do
    around do |example|
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "spec"))
        File.write(File.join(dir, ".rspec"), "--no-color\n")
        File.write(File.join(dir, "spec", "broken_spec.rb"), <<~SPEC)
          RSpec.describe "broken" do
            it "passes" do
              expect(true).to be(true)
            end
            it "fails the math" do
              expect(2 + 2).to eq(5)
            end
          end
        SPEC
        @dir = dir
        example.run
      end
    end

    it "returns the failure count and the parsed failing example" do
      in_workspace(@dir) do
        res = tool.call({})
        expect(res[:framework]).to eq("rspec")
        expect(res[:ran]).to be(true)
        expect(res[:examples]).to eq(2)
        expect(res[:failures]).to eq(1)
        expect(res[:error_code]).to eq(:tests_failed)
        expect(res[:exit_code]).not_to eq(0)

        expect(res[:failing].size).to eq(1)
        fail = res[:failing].first
        expect(fail[:description]).to include("fails the math")
        expect(fail[:location]).to match(/broken_spec\.rb:\d+/)
        expect(fail[:message]).to match(/expected.*5|got/i)

        # The model-facing summary lists the failing example.
        expect(res[:output]).to include("failing:")
        expect(res[:output]).to include("fails the math")
      end
    end
  end

  context "running a single file via `path`" do
    around do |example|
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "spec"))
        File.write(File.join(dir, ".rspec"), "--no-color\n")
        File.write(File.join(dir, "spec", "a_spec.rb"),
                   "RSpec.describe('a'){ it('ok'){ expect(1).to eq(1) } }\n")
        File.write(File.join(dir, "spec", "b_spec.rb"),
                   "RSpec.describe('b'){ it('boom'){ raise 'nope' } }\n")
        @dir = dir
        example.run
      end
    end

    it "runs only the given file" do
      in_workspace(@dir) do
        res = tool.call("path" => "spec/a_spec.rb")
        expect(res[:command]).to eq("rspec spec/a_spec.rb")
        expect(res[:examples]).to eq(1)
        expect(res[:failures]).to eq(0)
      end
    end
  end

  context "with a Minitest project" do
    around do |example|
      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "test"))
        File.write(File.join(dir, "test", "thing_test.rb"), <<~TEST)
          require "minitest/autorun"
          class ThingTest < Minitest::Test
            def test_passes
              assert_equal 4, 2 + 2
            end
            def test_fails
              assert_equal 5, 2 + 2
            end
          end
        TEST
        @dir = dir
        example.run
      end
    end

    # No Gemfile and no Rakefile, so for a subset run we go through
    # `ruby -Itest -Ilib <file>`; that's the most portable Minitest invocation
    # and lets us assert on parsed counts without a Rakefile.
    it "detects minitest and parses runs + failures" do
      in_workspace(@dir) do
        res = tool.call("path" => "test/thing_test.rb")
        expect(res[:framework]).to eq("minitest")
        expect(res[:command]).to eq("ruby -Itest -Ilib test/thing_test.rb")
        expect(res[:ran]).to be(true)
        expect(res[:examples]).to eq(2) # runs
        expect(res[:failures]).to eq(1)
        expect(res[:error_code]).to eq(:tests_failed)
        expect(res[:failing].first[:description]).to include("test_fails")
      end
    end

    it "detects minitest for a whole-suite run via rake" do
      in_workspace(@dir) do
        # Whole-suite (no path): falls back to `rake test` since there's no
        # bin/rails. We only assert detection + command shape here (no Rakefile
        # to actually run), which exercises the detection branch.
        framework = tool.send(:detect_framework, @dir)
        cmd       = tool.send(:build_command, @dir, "minitest", nil)
        expect(framework).to eq("minitest")
        expect(cmd).to eq("rake test")
      end
    end
  end

  it "honors an explicit framework override" do
    Dir.mktmpdir do |dir|
      # A spec/ dir would auto-detect rspec; force minitest via override and a
      # path so we get the deterministic ruby invocation.
      FileUtils.mkdir_p(File.join(dir, "spec"))
      FileUtils.mkdir_p(File.join(dir, "test"))
      File.write(File.join(dir, "test", "x_test.rb"),
                 "require 'minitest/autorun'\nclass XT < Minitest::Test\n def test_ok; assert true; end\nend\n")
      in_workspace(dir) do
        res = tool.call("framework" => "minitest", "path" => "test/x_test.rb")
        expect(res[:framework]).to eq("minitest")
        expect(res[:examples]).to eq(1)
        expect(res[:failures]).to eq(0)
      end
    end
  end
end
