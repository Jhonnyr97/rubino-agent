# frozen_string_literal: true

# End-to-end integration tests: Runner → Lifecycle → Agent::Loop → ToolExecutor → Tool
#
# These tests use FakeLLMAdapter to script LLM responses without hitting any
# real API. The goal is to verify the full call chain:
#   user input → message store → context assembly → LLM call → tool execution →
#   second LLM call → final response stored in session
RSpec.describe "Agent end-to-end with FakeLLMAdapter" do
  let(:db)        { test_database }
  let(:null_ui)   { Rubino::UI::Null.new }
  let(:fake_llm)  { FakeLLMAdapter.new }
  # Memory auto-extraction and skill auto-distillation are exercised in their
  # own specs; here they would just consume scripted FakeLLM turns (both mine
  # the just-finished transcript via an aux LLM call), so disable both for these
  # conversation/tool-loop tests. Leaving auto_distill on would fire
  # DistillSkillJob inline on every >= 5-tool turn against an already-exhausted
  # FakeLLM, which retries with exponential backoff and pollutes later specs.
  let(:config) do
    mem    = Rubino::Config::Defaults.dig("memory").merge("auto_extract" => false)
    skills = Rubino::Config::Defaults.dig("skills").merge("auto_distill" => false)
    test_configuration("memory" => mem, "skills" => skills)
  end

  before do
    allow(Rubino).to receive(:database).and_return(db)
    allow(Rubino).to receive(:ui).and_return(null_ui)
    allow(Rubino).to receive(:configuration).and_return(config)
    allow(Rubino).to receive(:event_bus).and_return(Rubino::Interaction::EventBus.new)

    # Inject the FakeLLMAdapter into Lifecycle so no real HTTP calls are made
    allow(Rubino::LLM::RubyLLMAdapter).to receive(:new).and_return(fake_llm)
  end

  def build_runner(**opts)
    Rubino::Agent::Runner.new(ui: null_ui, **opts)
  end

  # ---------------------------------------------------------------------------
  # Basic conversation: single turn, text-only response
  # ---------------------------------------------------------------------------

  describe "single text-only turn" do
    it "returns the assistant response and stores it in the session" do
      fake_llm.enqueue_text("Hello from the fake LLM!")
      runner = build_runner
      result = runner.run("hello")
      expect(result).to eq("Hello from the fake LLM!")
    end

    it "creates a session on first run" do
      fake_llm.enqueue_text("ok")
      runner = build_runner
      runner.run("hi")

      repo    = Rubino::Session::Repository.new
      session = repo.find(runner.session[:id])
      expect(session).not_to be_nil
      expect(session[:status]).to eq("active")
    end

    it "records the user message in the message store" do
      fake_llm.enqueue_text("got it")
      runner = build_runner
      runner.run("test input")

      store    = Rubino::Session::Store.new
      messages = store.for_session(runner.session[:id])
      user_msgs = messages.select { |m| m.role == "user" }
      expect(user_msgs.map(&:content)).to include("test input")
    end

    it "records the assistant response in the message store" do
      fake_llm.enqueue_text("stored response")
      runner = build_runner
      runner.run("anything")

      store    = Rubino::Session::Store.new
      messages = store.for_session(runner.session[:id])
      assistant_msgs = messages.select { |m| m.role == "assistant" }
      expect(assistant_msgs.map(&:content)).to include("stored response")
    end
  end

  # ---------------------------------------------------------------------------
  # Multi-turn conversation
  # ---------------------------------------------------------------------------

  describe "multi-turn conversation on the same session" do
    it "resumes the same session for the second turn" do
      fake_llm.enqueue_text("turn 1 response")
      fake_llm.enqueue_text("turn 2 response")

      runner = build_runner
      runner.run("first message")
      result2 = runner.run("second message")

      expect(result2).to eq("turn 2 response")
    end

    it "accumulates messages across turns in the same session" do
      fake_llm.enqueue_text("first")
      fake_llm.enqueue_text("second")

      runner = build_runner
      runner.run("msg 1")
      runner.run("msg 2")

      store    = Rubino::Session::Store.new
      messages = store.for_session(runner.session[:id])
      roles    = messages.map(&:role)
      # Should have user, assistant, user, assistant
      expect(roles.count("user")).to be >= 2
      expect(roles.count("assistant")).to be >= 2
    end
  end

  # ---------------------------------------------------------------------------
  # Tool call → follow-up response
  # ---------------------------------------------------------------------------

  describe "tool call cycle" do
    let(:tmp_dir) { Dir.mktmpdir("e2e_tool") }

    after         { FileUtils.rm_rf(tmp_dir) }

    before do
      # Register ReadTool in the global registry so Lifecycle can find it
      Rubino::Tools::Registry.instance.reset!
      Rubino::Tools::Registry.instance.register(Rubino::Tools::ReadTool.new)

      # Disable approval so tool runs automatically
      allow(Rubino.configuration).to receive(:approvals_mode).and_return("auto")
    end

    it "executes a read tool call and returns the follow-up LLM response" do
      test_file = File.join(tmp_dir, "hello.txt")
      File.write(test_file, "file contents here")

      fake_llm.enqueue_tool_call("read", { "file_path" => test_file })
      fake_llm.enqueue_text("I read the file successfully.")

      runner = build_runner
      result = runner.run("read #{test_file}")
      expect(result).to eq("I read the file successfully.")
    end

    it "passes the tool result back to the LLM in the second call" do
      test_file = File.join(tmp_dir, "data.txt")
      File.write(test_file, "secret data 42")

      fake_llm.enqueue_tool_call("read", { "file_path" => test_file })
      fake_llm.enqueue_text("Done")

      runner = build_runner
      runner.run("read the file")

      second_call_messages = fake_llm.calls.last[:messages]
      tool_result = second_call_messages.find { |m| m[:role] == "tool" }
      expect(tool_result).not_to be_nil
      expect(tool_result[:content]).to include("secret data 42")
    end
  end

  # ---------------------------------------------------------------------------
  # Error handling
  # ---------------------------------------------------------------------------

  describe "error handling" do
    it "returns nil and emits an error to the UI when the LLM raises" do
      fake_llm.enqueue_error("LLM timeout")
      runner = build_runner
      result = runner.run("will fail")
      expect(result).to be_nil

      error_msgs = null_ui.messages.select { |m| m[:level] == :error }
      expect(error_msgs).not_to be_empty
    end
  end

  # ---------------------------------------------------------------------------
  # Session resume by ID
  # ---------------------------------------------------------------------------

  describe "session resume" do
    it "resumes an existing session by ID" do
      fake_llm.enqueue_text("first turn")
      runner1 = build_runner
      runner1.run("first")
      sid = runner1.session[:id]

      fake_llm.enqueue_text("resumed response")
      runner2 = build_runner(session_id: sid)
      result = runner2.run("resumed")

      expect(result).to eq("resumed response")
      expect(runner2.session[:id]).to eq(sid)
    end

    it "raises SessionError for an unknown session ID" do
      expect do
        build_runner(session_id: "nonexistent-id-0000")
      end.to raise_error(Rubino::SessionError)
    end
  end
end
