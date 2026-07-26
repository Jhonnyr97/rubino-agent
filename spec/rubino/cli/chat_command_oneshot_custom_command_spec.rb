# frozen_string_literal: true

require "tmpdir"
require "fileutils"

# Custom slash commands (.rubino/commands/*.md et al) expanded correctly
# inside the interactive `rubino chat` REPL but did NOTHING in
# one-shot mode: `rubino chat -q "/mycommand args"` sent the literal,
# unrendered "/mycommand args" straight to the model instead of routing it
# through Commands::Loader/Command#render first. This spec drives the REAL
# one-shot path end-to-end (ChatCommand#execute -> run_oneshot ->
# setup_oneshot) against a scriptable FakeLLMAdapter and asserts both what
# the model actually received AND what got persisted to the session's
# messages table are the EXPANDED template — never the literal "/name args".
RSpec.describe Rubino::CLI::ChatCommand do
  let(:db)       { test_database }
  let(:null_ui)  { Rubino::UI::Null.new }
  let(:fake_llm) { FakeLLMAdapter.new }
  let(:commands_dir) { Dir.mktmpdir("rubino-oneshot-commands") }

  let(:config) do
    mem    = Rubino::Config::Defaults.to_hash["memory"].merge("auto_extract" => false)
    skills = Rubino::Config::Defaults.to_hash["skills"].merge("auto_distill" => false)
    commands = Rubino::Config::Defaults.to_hash["commands"].merge("paths" => [commands_dir])
    test_configuration("memory" => mem, "skills" => skills, "commands" => commands)
  end

  before do
    allow(Rubino).to receive_messages(database: db, configuration: config)
    allow(Rubino::LLM::RubyLLMAdapter).to receive(:new).and_return(fake_llm)
    allow(Rubino::LLM::CredentialCheck).to receive(:usable?).and_return(true)
    Rubino.ui = null_ui
    Rubino.logger = nil
    Rubino::Modes.reset!
  end

  after do
    Rubino.logger = nil
    FileUtils.rm_rf(commands_dir)
  end

  # Runs a one-shot, capturing stdout + stderr and any SystemExit status.
  def run_oneshot(opts)
    out = StringIO.new
    err = StringIO.new
    status = 0
    orig_out = $stdout
    orig_err = $stderr
    $stdout = out
    $stderr = err
    begin
      described_class.new(opts).execute
    rescue SystemExit => e
      status = e.status
    ensure
      $stdout = orig_out
      $stderr = orig_err
    end
    [out.string, err.string, status]
  end

  def write_command(name, template)
    File.write(File.join(commands_dir, "#{name}.md"), template)
  end

  # The last user-role message the fake adapter actually received, across
  # every call it recorded this run.
  def last_user_content_sent_to_llm
    fake_llm.received_messages.last
            &.reverse
            &.find { |m| (m[:role] || m["role"]) == "user" }
            &.then { |m| m[:content] || m["content"] }
  end

  # The last user-role message persisted to the (single) session this test's
  # isolated in-memory DB holds — one-shot mode never auto-resumes, so a fresh
  # test DB has exactly one session per run_oneshot call.
  def last_persisted_user_message
    db.db[:messages].where(role: "user").order(:created_at).all.last
  end

  describe "a plain $ARGUMENTS template" do
    it "expands the template and sends/persists the RENDERED text, not the literal command line" do
      write_command("greet", "Say hello to $ARGUMENTS in a friendly tone.\n")
      fake_llm.enqueue_text("Hello, Bob!", input_tokens: 6, output_tokens: 3)

      stdout, _stderr, status = run_oneshot("query" => "/greet Bob", "yolo" => true)

      expect(status).to eq(0)
      expect(stdout.strip).to eq("Hello, Bob!")

      sent = last_user_content_sent_to_llm
      expect(sent).to eq("Say hello to Bob in a friendly tone.")
      expect(sent).not_to include("/greet")
    end

    it "persists the expanded template to the messages table (not the raw /command line)" do
      write_command("greet", "Say hello to $ARGUMENTS in a friendly tone.\n")
      fake_llm.enqueue_text("Hello, Bob!", input_tokens: 6, output_tokens: 3)

      run_oneshot("query" => "/greet Bob", "yolo" => true)

      persisted = last_persisted_user_message
      expect(persisted).not_to be_nil
      expect(persisted[:content]).to eq("Say hello to Bob in a friendly tone.")
      expect(persisted[:content]).not_to include("/greet")
    end
  end

  describe "positional $1/$2 params and multiple args" do
    it "substitutes positional params in addition to $ARGUMENTS" do
      write_command("review", "Review $1 against $2. Full args: $ARGUMENTS\n")
      fake_llm.enqueue_text("reviewed", input_tokens: 6, output_tokens: 3)

      run_oneshot("query" => "/review the-diff the-spec", "yolo" => true)

      sent = last_user_content_sent_to_llm
      expect(sent).to eq("Review the-diff against the-spec. Full args: the-diff the-spec")
    end
  end

  describe "an @file reference inside the template" do
    it "inlines the referenced file's content" do
      support_file = File.join(commands_dir, "context.txt")
      File.write(support_file, "IMPORTANT CONTEXT LINE")
      write_command("withfile", "Context follows:\n@#{support_file}\n")
      fake_llm.enqueue_text("ok", input_tokens: 6, output_tokens: 3)

      run_oneshot("query" => "/withfile", "yolo" => true)

      sent = last_user_content_sent_to_llm
      expect(sent).to include("IMPORTANT CONTEXT LINE")
      expect(sent).not_to include("/withfile")
    end
  end

  describe "an unmatched slash-prefixed one-shot query" do
    it "falls through and is sent verbatim (not intercepted as an unknown command)" do
      fake_llm.enqueue_text("that's a path, not a command", input_tokens: 6, output_tokens: 3)

      stdout, stderr, status = run_oneshot(
        "query" => "/etc/hosts explain this file", "yolo" => true
      )

      expect(status).to eq(0)
      expect(stdout.strip).to eq("that's a path, not a command")
      expect(stderr).not_to include("unknown command")

      sent = last_user_content_sent_to_llm
      expect(sent).to eq("/etc/hosts explain this file")
    end
  end

  describe "a custom command with `agent:` frontmatter" do
    it "routes the one-shot turn to the named agent's Definition" do
      write_command("explorer-task", <<~MD)
        ---
        agent: explore
        ---
        Investigate $ARGUMENTS
      MD
      fake_llm.enqueue_text("investigated", input_tokens: 6, output_tokens: 3)

      run_oneshot("query" => "/explorer-task the parser", "yolo" => true)

      sent = last_user_content_sent_to_llm
      expect(sent).to eq("Investigate the parser")
      # The explore agent's system prompt rode this turn (proof the
      # frontmatter's agent: was actually applied, not silently dropped).
      system_msg = fake_llm.received_messages.last.find { |m| (m[:role] || m["role"]) == "system" }
      system_content = (system_msg && (system_msg[:content] || system_msg["content"])).to_s
      expect(system_content).to include(Rubino.agent_registry.find("explore").system_prompt)
    end
  end

  describe "--output-format json" do
    it "also expands the template (setup_oneshot is shared by the text and json paths)" do
      write_command("greet", "Say hello to $ARGUMENTS in a friendly tone.\n")
      fake_llm.enqueue_text("Hello, Bob!", input_tokens: 6, output_tokens: 3)

      stdout, = run_oneshot(
        "query" => "/greet Bob", "yolo" => true, "output_format" => "json"
      )

      obj = JSON.parse(stdout.each_line.map(&:strip).reject(&:empty?).last)
      expect(obj["result"]).to eq("Hello, Bob!")

      sent = last_user_content_sent_to_llm
      expect(sent).to eq("Say hello to Bob in a friendly tone.")
    end
  end
end
