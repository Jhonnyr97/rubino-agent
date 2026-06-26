# frozen_string_literal: true

# Dispatch + output specs for the parent<->subagent comm slash verbs added to
# the Executor: /agents <id> steer and /agents <id> probe.
# Render/visual correctness is verified separately in the headless terminal.
RSpec.describe "Rubino::Commands::Executor comm verbs" do
  subject(:exec) { Rubino::Commands::Executor.new(loader: loader, ui: ui, runner: nil) }

  let(:db)     { test_database }
  let(:ui)     { Rubino::UI::Null.new }
  let(:loader) { Rubino::Commands::Loader.new(config: test_configuration) }

  before do
    allow(Rubino).to receive(:database).and_return(db)
    allow(Rubino).to receive(:configuration).and_return(test_configuration)
  end

  def info_lines
    ui.messages.select { |m| %i[info status success error].include?(m[:level]) }
               .map { |m| m[:message].to_s }
  end

  describe "/agents <id> steer" do
    it "pushes the note onto the child's steer queue and confirms it" do
      entry = Rubino::Tools::BackgroundTasks.instance.reserve(subagent: "explore", prompt: "x")
      exec.try_execute(%(/agents #{entry.id} steer "be terse"))

      expect(entry.steer_queue.drain).to eq(["be terse"])
      expect(info_lines.join("\n")).to include("steer ▸ #{entry.id}")
    end

    it "errors on an unknown id" do
      exec.try_execute(%(/agents sa_nope steer "hi"))
      expect(info_lines.join("\n")).to include("cannot steer sa_nope")
    end
  end

  describe "/agents <id> probe" do
    it "renders the ephemeral aside and never persists to the child" do
      Rubino::Tools::Registry.register_defaults!
      sess  = Rubino::Session::Repository.new.create(source: "test", model: "fake-model")
      store = Rubino::Session::Store.new
      store.create(session_id: sess[:id], role: "user", content: "explore auth")
      entry = Rubino::Tools::BackgroundTasks.instance.reserve(subagent: "explore", prompt: "x")
      entry.runner = double("runner", session: sess, model_id: "fake-model")

      fake = FakeLLMAdapter.new
      fake.enqueue_text("peeked answer")
      allow(Rubino::Tools::SubagentProbe).to receive(:new).and_return(
        Rubino::Tools::SubagentProbe.new(adapter_factory: ->(_m) { fake }, message_store: store)
      )

      before_count = store.count(sess[:id])
      exec.try_execute(%(/agents #{entry.id} probe "keeping compat?"))

      joined = info_lines.join("\n")
      expect(joined).to include("probe → #{entry.id}")
      expect(joined).to include("ephemeral · not saved")
      expect(joined).to include("peeked answer")
      # #112: a child with no tool activity yet gets the at-this-instant hint
      # so its honest "I'm not doing anything" answer doesn't read as broken.
      expect(joined).to include("snapshot at this instant")
      expect(store.count(sess[:id])).to eq(before_count)
    end
  end
end
