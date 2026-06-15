# frozen_string_literal: true

# #380 — in HEADLESS one-shot mode (`rubino prompt`/-q) there is no IdleCardHost
# to fold a background subagent's result back in, and the process exits the
# instant the parent's answer is ready, so a `background: true` task would be
# silently dropped (its notice sink is nil, its thread killed on exit). The fix
# forces `task` subagents FOREGROUND in headless mode so the child runs to
# completion inline and its result is returned as THIS tool's result — landing
# in the parent transcript and factored into the one-shot answer.
RSpec.describe Rubino::Tools::TaskTool do
  let(:db)     { test_database }
  let(:config) { test_configuration }

  before do
    allow(Rubino).to receive(:database).and_return(db)
    Rubino::Tools::Registry.register_defaults!
    Rubino.agent_registry = Rubino::Agent::AgentRegistry.new
  end

  after { Rubino.agent_registry = nil }

  # A runner that records whether run! was called on the CALLING thread (i.e.
  # synchronously) and returns a canned result.
  def recording_runner(final, seen)
    Class.new do
      define_method(:run!) do |input, **_opts|
        seen << input
        final
      end
      define_method(:cancel!) {}
    end.new
  end

  describe "background task in headless one-shot mode (#380)" do
    it "runs the subagent FOREGROUND and returns its result as the tool result" do
      seen   = []
      runner = recording_runner("the child answer is 42", seen)
      tool   = described_class.new(runner_factory: ->(_d) { runner })

      # background defaults to true; under Rubino.with_headless it must be
      # forced foreground, so the call returns the CHILD's result directly
      # (not a "Started background subagent …" handle) and the child ran.
      out = Rubino.with_headless do
        tool.call("subagent" => "explore", "prompt" => "compute")
      end

      expect(out).to eq("the child answer is 42")
      expect(out).not_to include("Started background subagent")
      expect(seen).to eq(["compute"])
      # Nothing was left running in the background registry.
      expect(Rubino::Tools::BackgroundTasks.instance.running).to be_empty
    end

    it "still backgrounds (returns a handle, does NOT block) when NOT headless" do
      latch  = Queue.new
      runner = Class.new do
        define_method(:run!) { |_i, **_o| latch.pop }
        define_method(:cancel!) {}
      end.new
      tool = described_class.new(runner_factory: ->(_d) { runner })

      out = tool.call("subagent" => "explore", "prompt" => "slow")
      expect(out).to include("Started background subagent 'explore' as task sa_")

      latch << "done" # release the worker so the thread doesn't leak
    end
  end
end
