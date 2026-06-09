# frozen_string_literal: true

RSpec.describe Rubino::Commands::Loader do
  let(:tmp_dir) { Dir.mktmpdir("rubino_loader_test") }
  let(:config) do
    test_configuration("commands" => { "paths" => [tmp_dir] })
  end

  subject(:loader) { described_class.new(config: config) }

  after { FileUtils.rm_rf(tmp_dir) }

  # -----------------------------------------------------------------------
  # slash_command?
  # -----------------------------------------------------------------------

  describe "#slash_command?" do
    it "returns true for input starting with /" do
      expect(loader.slash_command?("/help")).to be true
    end

    it "returns true with leading whitespace" do
      expect(loader.slash_command?("  /help")).to be true
    end

    it "returns false for normal input" do
      expect(loader.slash_command?("hello")).to be false
    end

    it "returns false for empty string" do
      expect(loader.slash_command?("")).to be false
    end
  end

  # -----------------------------------------------------------------------
  # parse
  # -----------------------------------------------------------------------

  describe "#parse" do
    it "parses command name without arguments" do
      expect(loader.parse("/help")).to eq(["help", ""])
    end

    it "parses command name with arguments" do
      expect(loader.parse("/review my_file.rb")).to eq(["review", "my_file.rb"])
    end

    it "parses multi-word arguments" do
      expect(loader.parse("/test arg1 arg2 arg3")).to eq(["test", "arg1 arg2 arg3"])
    end

    it "strips leading whitespace" do
      expect(loader.parse("  /help")).to eq(["help", ""])
    end

    it "returns nil for non-slash input" do
      expect(loader.parse("hello")).to be_nil
    end
  end

  # -----------------------------------------------------------------------
  # discover! and all
  # -----------------------------------------------------------------------

  describe "#discover!" do
    it "returns empty when no command files exist" do
      expect(loader.all).to be_empty
    end

    it "discovers .md files as commands" do
      File.write(File.join(tmp_dir, "review.md"), "---\nname: review\ndescription: Code review\n---\nReview this code")
      File.write(File.join(tmp_dir, "test.md"),   "---\nname: test\ndescription: Run tests\n---\nRun the tests")

      expect(loader.all.size).to eq(2)
      expect(loader.names).to contain_exactly("/review", "/test")
    end

    it "ignores non-.md files" do
      File.write(File.join(tmp_dir, "command.rb"), "# not a command")
      File.write(File.join(tmp_dir, "review.md"),  "Review")
      expect(loader.all.size).to eq(1)
    end

    it "uses filename as name when no frontmatter" do
      File.write(File.join(tmp_dir, "deploy.md"), "Deploy the app")
      cmd = loader.find("deploy")
      expect(cmd.name).to eq("deploy")
    end

    it "skips a command with non-Hash YAML frontmatter without crashing (#79)" do
      File.write(File.join(tmp_dir, "arr.md"), "---\n- one\n- two\n---\nHello array")
      File.write(File.join(tmp_dir, "review.md"), "---\nname: review\n---\nReview")

      names = nil
      expect { names = loader.names }.not_to raise_error
      # The malformed file falls back to its basename and the valid one still loads.
      expect(names).to include("/review")
    end

    it "skips a command with malformed YAML frontmatter without crashing (#79)" do
      File.write(File.join(tmp_dir, "bad.md"), "---\nname: [unclosed\n---\nbody")
      File.write(File.join(tmp_dir, "ok.md"), "---\nname: ok\n---\nok")

      expect { loader.all }.not_to raise_error
      expect(loader.names).to include("/ok")
    end
  end

  # -----------------------------------------------------------------------
  # find
  # -----------------------------------------------------------------------

  describe "#find" do
    before do
      File.write(File.join(tmp_dir, "review.md"), "---\nname: review\ndescription: Review\n---\nContent")
    end

    it "finds command by name" do
      expect(loader.find("review")).not_to be_nil
    end

    it "finds command stripping leading slash" do
      expect(loader.find("/review")).not_to be_nil
    end

    it "returns nil for unknown command" do
      expect(loader.find("unknown")).to be_nil
    end
  end

  # -----------------------------------------------------------------------
  # names
  # -----------------------------------------------------------------------

  describe "#names" do
    it "returns names prefixed with /" do
      File.write(File.join(tmp_dir, "deploy.md"), "Deploy")
      expect(loader.names).to eq(["/deploy"])
    end

    it "returns empty array when no commands" do
      expect(loader.names).to eq([])
    end
  end
end


RSpec.describe Rubino::Commands::Command do
  let(:tmp_dir) { Dir.mktmpdir("rubino_command_test") }

  after { FileUtils.rm_rf(tmp_dir) }

  def write_command(filename, content)
    path = File.join(tmp_dir, filename)
    File.write(path, content)
    described_class.new(path: path)
  end

  # -----------------------------------------------------------------------
  # Frontmatter parsing
  # -----------------------------------------------------------------------

  describe "frontmatter parsing" do
    it "reads name from frontmatter" do
      cmd = write_command("review.md", "---\nname: code-review\ndescription: Review code\n---\nContent")
      expect(cmd.name).to eq("code-review")
    end

    it "reads description from frontmatter" do
      cmd = write_command("review.md", "---\nname: review\ndescription: My description\n---\nContent")
      expect(cmd.description).to eq("My description")
    end

    it "falls back to filename when no frontmatter name" do
      cmd = write_command("deploy.md", "Deploy the app\n")
      expect(cmd.name).to eq("deploy")
    end

    it "reads agent from frontmatter" do
      cmd = write_command("plan.md", "---\nagent: plan\n---\nContent")
      expect(cmd.agent).to eq("plan")
    end

    it "reads model from frontmatter" do
      cmd = write_command("fast.md", "---\nmodel: claude-3-haiku\n---\nContent")
      expect(cmd.model).to eq("claude-3-haiku")
    end

    it "handles missing frontmatter gracefully" do
      cmd = write_command("simple.md", "Just some content\n")
      expect(cmd.name).to eq("simple")
      expect(cmd.description).to eq("")
    end
  end

  # -----------------------------------------------------------------------
  # render — $ARGUMENTS substitution
  # -----------------------------------------------------------------------

  describe "#render — $ARGUMENTS" do
    it "replaces $ARGUMENTS with provided arguments" do
      cmd = write_command("review.md", "---\nname: review\n---\nReview this: $ARGUMENTS")
      expect(cmd.render("my_file.rb")).to eq("Review this: my_file.rb")
    end

    it "replaces $ARGUMENTS with empty string when no args" do
      cmd = write_command("review.md", "---\nname: review\n---\nReview this: $ARGUMENTS")
      expect(cmd.render("")).to eq("Review this:")
    end
  end

  # -----------------------------------------------------------------------
  # render — positional params $1, $2, $3
  # -----------------------------------------------------------------------

  describe "#render — positional params" do
    it "replaces $1 with first argument" do
      cmd = write_command("cmd.md", "---\nname: cmd\n---\nFirst: $1 Second: $2")
      expect(cmd.render("foo bar")).to eq("First: foo Second: bar")
    end

    it "replaces $1 when only one arg" do
      cmd = write_command("cmd.md", "---\nname: cmd\n---\nArg: $1")
      expect(cmd.render("hello")).to eq("Arg: hello")
    end

    it "replaces missing positional params with empty string" do
      cmd = write_command("cmd.md", "---\nname: cmd\n---\n$1 $2 $3")
      # strip removes trailing spaces, so the result is trimmed
      expect(cmd.render("only_one")).to eq("only_one")
    end
  end

  # -----------------------------------------------------------------------
  # render — shell injection !`command`
  # -----------------------------------------------------------------------

  describe "#render — shell injection" do
    context "when shell_injection_enabled is true" do
      before do
        allow(Rubino.configuration).to receive(:dig)
          .with("commands", "shell_injection_enabled").and_return(true)
      end

      it "replaces !`command` with shell output" do
        cmd = write_command("cmd.md", "---\nname: cmd\n---\nDate: !`echo hello`")
        expect(cmd.render("")).to eq("Date: hello")
      end

      it "handles failed shell commands gracefully" do
        cmd = write_command("cmd.md", "---\nname: cmd\n---\nResult: !`nonexistent_cmd_xyz 2>/dev/null`")
        expect { cmd.render("") }.not_to raise_error
      end
    end

    context "when shell_injection_enabled is false (default)" do
      it "does not execute shell commands and leaves !`...` as-is" do
        cmd = write_command("cmd.md", "---\nname: cmd\n---\nDate: !`echo hello`")
        result = cmd.render("")
        expect(result).to include("!`echo hello`")
        expect(result).not_to eq("Date: hello")
      end
    end
  end

  # -----------------------------------------------------------------------
  # render — @file references
  # -----------------------------------------------------------------------

  describe "#render — @file references" do
    it "replaces @path with file contents" do
      file_path = File.join(tmp_dir, "context.txt")
      File.write(file_path, "file content here")

      cmd = write_command("cmd.md", "---\nname: cmd\n---\nContext: @#{file_path}")
      expect(cmd.render("")).to include("file content here")
    end

    it "replaces @missing_file with error note" do
      cmd = write_command("cmd.md", "---\nname: cmd\n---\nContext: @/nonexistent/file.txt")
      result = cmd.render("")
      expect(result).to include("file not found")
    end
  end
end


RSpec.describe Rubino::Commands::Executor do
  let(:null_ui) { Rubino::UI::Null.new }
  let(:loader)  { instance_double(Rubino::Commands::Loader) }

  subject(:executor) { described_class.new(loader: loader, ui: null_ui) }

  before do
    allow(loader).to receive(:slash_command?).and_return(true)
    allow(loader).to receive(:all).and_return([])
    allow(loader).to receive(:names).and_return([])
  end

  # -----------------------------------------------------------------------
  # try_execute — non slash input
  # -----------------------------------------------------------------------

  describe "#try_execute — non-slash input" do
    it "returns nil for non-slash input" do
      allow(loader).to receive(:slash_command?).and_return(false)
      expect(executor.try_execute("hello")).to be_nil
    end
  end

  # -----------------------------------------------------------------------
  # Built-in commands
  # -----------------------------------------------------------------------

  describe "/help" do
    before { allow(loader).to receive(:parse).and_return(["help", ""]) }

    it "returns :handled" do
      expect(executor.try_execute("/help")).to eq(:handled)
    end

    it "prints built-in command list to UI" do
      executor.try_execute("/help")
      messages = null_ui.messages.map { |m| m[:message] }
      expect(messages).to include(a_string_including("Built-in"))
    end

    it "shows custom commands if any exist" do
      cmd = instance_double(Rubino::Commands::Command, name: "review", description: "Review code")
      allow(loader).to receive(:all).and_return([cmd])

      executor.try_execute("/help")
      messages = null_ui.messages.map { |m| m[:message] }
      expect(messages).to include(a_string_including("/review"))
    end

    it "documents /quit and /mode (previously omitted, L7)" do
      executor.try_execute("/help")
      joined = null_ui.messages.map { |m| m[:message] }.join("\n")
      %w[/help /commands /skills /mode /exit /quit].each do |name|
        expect(joined).to include(name)
      end
    end
  end

  describe "/exit" do
    before { allow(loader).to receive(:parse).and_return(["exit", ""]) }

    it "returns :exit" do
      expect(executor.try_execute("/exit")).to eq(:exit)
    end
  end

  describe "/quit" do
    before { allow(loader).to receive(:parse).and_return(["quit", ""]) }

    it "returns :exit" do
      expect(executor.try_execute("/quit")).to eq(:exit)
    end
  end

  describe "/commands" do
    before { allow(loader).to receive(:parse).and_return(["commands", ""]) }

    it "returns :handled" do
      expect(executor.try_execute("/commands")).to eq(:handled)
    end

    it "shows message when no commands" do
      executor.try_execute("/commands")
      messages = null_ui.messages.map { |m| m[:message] }
      expect(messages).to include(a_string_including("No custom commands found"))
    end

    it "lists custom commands when present" do
      cmd = instance_double(Rubino::Commands::Command, name: "deploy", description: "Deploy app")
      allow(loader).to receive(:all).and_return([cmd])

      executor.try_execute("/commands")
      messages = null_ui.messages.map { |m| m[:message] }
      expect(messages).to include(a_string_including("/deploy"))
    end
  end

  describe "/skills" do
    let(:registry) { instance_double(Rubino::Skills::Registry) }

    before do
      allow(loader).to receive(:parse).and_return(["skills", ""])
      allow(Rubino::Skills::Registry).to receive(:new).and_return(registry)
    end

    it "returns :handled" do
      allow(registry).to receive(:all).and_return([])
      expect(executor.try_execute("/skills")).to eq(:handled)
    end

    it "shows no-skills message when empty" do
      allow(registry).to receive(:all).and_return([])
      executor.try_execute("/skills")
      messages = null_ui.messages.map { |m| m[:message] }
      expect(messages).to include(a_string_including("No skills found"))
    end

    it "lists skills when present" do
      skill = instance_double(Rubino::Skills::Skill, name: "ruby-expert", description: "Ruby help")
      allow(registry).to receive(:all).and_return([skill])
      allow(registry).to receive(:enabled?).with("ruby-expert").and_return(true)

      executor.try_execute("/skills")
      messages = null_ui.messages.map { |m| m[:message] }
      expect(messages).to include(a_string_including("ruby-expert"))
    end

    it "marks a disabled skill as (disabled)" do
      skill = instance_double(Rubino::Skills::Skill, name: "ruby-expert", description: "Ruby help")
      allow(registry).to receive(:all).and_return([skill])
      allow(registry).to receive(:enabled?).with("ruby-expert").and_return(false)

      executor.try_execute("/skills")
      messages = null_ui.messages.map { |m| m[:message] }
      expect(messages).to include(a_string_including("ruby-expert (disabled)"))
    end

    # B8: a long description used to be hard-wrapped mid-word at the terminal
    # edge ("officia\nl"). It must break only on whitespace; no emitted line
    # should split one of the description's words across two lines.
    it "word-wraps a long description without breaking mid-word (B8)" do
      desc  = "official harness that fans out web searches and synthesizes a cited report"
      skill = instance_double(Rubino::Skills::Skill, name: "deep-research", description: desc)
      allow(registry).to receive(:all).and_return([skill])
      allow(registry).to receive(:enabled?).with("deep-research").and_return(true)
      allow(executor).to receive(:terminal_width).and_return(40)

      executor.try_execute("/skills")
      lines = null_ui.messages.map { |m| m[:message] }.grep(/\S/)

      # Multiple lines (it wrapped) and each word stays intact across the output.
      expect(lines.size).to be > 1
      desc.split.each do |word|
        expect(lines.any? { |l| l.include?(word) }).to be(true), "word #{word.inspect} was split"
      end
    end
  end

  # -----------------------------------------------------------------------
  # Custom commands
  # -----------------------------------------------------------------------

  describe "custom command execution" do
    let(:custom_cmd) do
      instance_double(
        Rubino::Commands::Command,
        name: "review",
        description: "Code review",
        agent: nil,
        model: nil
      )
    end

    before do
      allow(loader).to receive(:parse).and_return(["review", "src/main.rb"])
      allow(loader).to receive(:find).with("review").and_return(custom_cmd)
    end

    it "returns a Hash with prompt when command found" do
      allow(custom_cmd).to receive(:render).with("src/main.rb").and_return("Please review src/main.rb")
      result = executor.try_execute("/review src/main.rb")
      expect(result).to be_a(Hash)
      expect(result[:prompt]).to eq("Please review src/main.rb")
    end

    it "passes arguments to command.render" do
      allow(custom_cmd).to receive(:render).with("src/main.rb").and_return("rendered")
      executor.try_execute("/review src/main.rb")
      expect(custom_cmd).to have_received(:render).with("src/main.rb")
    end

    it "includes agent and model from command" do
      cmd = instance_double(
        Rubino::Commands::Command,
        name: "plan", description: "Plan",
        agent: "plan", model: "claude-3-haiku"
      )
      allow(cmd).to receive(:render).and_return("plan prompt")
      allow(loader).to receive(:parse).and_return(["plan", ""])
      allow(loader).to receive(:find).with("plan").and_return(cmd)

      result = executor.try_execute("/plan")
      expect(result[:agent]).to eq("plan")
      expect(result[:model]).to eq("claude-3-haiku")
    end

    it "prints status message when executing custom command" do
      allow(custom_cmd).to receive(:render).and_return("rendered")
      executor.try_execute("/review src/main.rb")
      messages = null_ui.messages.map { |m| m[:message] }
      expect(messages).to include(a_string_including("Running command: /review"))
    end
  end

  # -----------------------------------------------------------------------
  # Unknown command
  # -----------------------------------------------------------------------

  describe "unknown command" do
    before do
      allow(loader).to receive(:parse).and_return(["unknown_cmd", ""])
      allow(loader).to receive(:find).with("unknown_cmd").and_return(nil)
    end

    it "returns :handled" do
      expect(executor.try_execute("/unknown_cmd")).to eq(:handled)
    end

    it "prints error message" do
      executor.try_execute("/unknown_cmd")
      error_msgs = null_ui.messages.select { |m| m[:level] == :error }.map { |m| m[:message] }
      expect(error_msgs).to include(a_string_including("Unknown command"))
    end

    it "lists the built-in commands in the Available hint even when no custom commands exist (L6)" do
      allow(loader).to receive(:names).and_return([])
      executor.try_execute("/unknown_cmd")
      info_msgs = null_ui.messages.select { |m| m[:level] == :info }.map { |m| m[:message] }
      available = info_msgs.find { |m| m.include?("Available:") }
      expect(available).not_to be_nil
      # The hint enumerates the real built-ins (previously empty).
      %w[/help /commands /skills /mode /exit /quit].each do |name|
        expect(available).to include(name)
      end
    end

    it "includes custom command names alongside the built-ins" do
      allow(loader).to receive(:names).and_return(["/deploy"])
      executor.try_execute("/unknown_cmd")
      info_msgs = null_ui.messages.select { |m| m[:level] == :info }.map { |m| m[:message] }
      expect(info_msgs.find { |m| m.include?("Available:") }).to include("/deploy")
    end
  end
end


RSpec.describe "ChatCommand slash command integration" do
  let(:db)      { test_database }
  let(:null_ui) { Rubino::UI::Null.new }

  let(:fake_runner) do
    # session must be stubbed: run_interactive now calls
    # print_session_history(ui, runner.session[:id]) right before the loop, and
    # end_session! is called on the clean teardown path (#100).
    instance_double(Rubino::Agent::Runner, run: "LLM response",
                                              session: { id: "spec-session-id" },
                                              end_session!: nil)
  end

  let(:fake_executor) do
    instance_double(Rubino::Commands::Executor)
  end

  before do
    allow(Rubino::Agent::Runner).to receive(:new).and_return(fake_runner)
    allow(Rubino::Commands::Executor).to receive(:new).and_return(fake_executor)
    allow(Rubino).to receive(:database).and_return(db)
    allow(db).to receive(:healthy?).and_return(true)
    allow_any_instance_of(Rubino::CLI::ChatCommand).to receive(:build_completion_source)
    Rubino.ui = null_ui
  end

  # Simulates an interactive input sequence by stubbing the idle line read
  # (#next_input — the single seam the REPL pulls each prompt from), avoiding the
  # raw-mode composer / Reline entirely in tests.
  def with_input(*inputs)
    call_count = -1
    allow_any_instance_of(Rubino::CLI::ChatCommand).to receive(:next_input) do
      call_count += 1
      inputs[call_count]
    end
    allow_any_instance_of(Rubino::CLI::ChatCommand).to receive(:build_completion_source)
  end

  describe "slash command routing in interactive mode" do
    it "sends /help to executor, does NOT call runner" do
      with_input("/help", nil)
      allow(fake_executor).to receive(:try_execute).with("/help").and_return(:handled)

      Rubino::CLI::ChatCommand.new({}).execute

      expect(fake_executor).to have_received(:try_execute).with("/help")
      expect(fake_runner).not_to have_received(:run)
    end

    it "breaks loop when executor returns :exit for /stop command" do
      # Note: /exit and /quit are caught by exit_command? before reaching executor.
      # Other slash commands that return :exit would be custom ones.
      with_input("/stop")
      allow(fake_executor).to receive(:try_execute).with("/stop").and_return(:exit)

      Rubino::CLI::ChatCommand.new({}).execute

      expect(fake_executor).to have_received(:try_execute).with("/stop")
      expect(fake_runner).not_to have_received(:run)
    end

    it "sends rendered prompt to runner when executor returns Hash" do
      with_input("/review main.rb", nil)
      allow(fake_executor).to receive(:try_execute).with("/review main.rb").and_return(
        { prompt: "Please review main.rb", agent: nil, model: nil }
      )

      Rubino::CLI::ChatCommand.new({}).execute

      expect(fake_runner).to have_received(:run).with("Please review main.rb", image_paths: [], input_queue: anything)
    end

    it "sends unknown slash command to runner when executor returns nil" do
      with_input("/unknown_custom", nil)
      allow(fake_executor).to receive(:try_execute).with("/unknown_custom").and_return(nil)

      Rubino::CLI::ChatCommand.new({}).execute

      expect(fake_runner).to have_received(:run).with("/unknown_custom", image_paths: [], input_queue: anything)
    end

    it "sends normal text directly to runner without going through executor" do
      with_input("hello world", nil)

      Rubino::CLI::ChatCommand.new({}).execute

      # Executor is instantiated but try_execute should never be called for non-slash input
      expect(fake_runner).to have_received(:run).with("hello world", image_paths: [], input_queue: anything)
    end

    it "breaks loop on exit command without calling executor" do
      with_input("exit")
      allow(fake_executor).to receive(:try_execute)

      Rubino::CLI::ChatCommand.new({}).execute

      expect(fake_executor).not_to have_received(:try_execute)
      expect(fake_runner).not_to have_received(:run)
    end

    it "breaks loop on nil input" do
      with_input(nil)

      Rubino::CLI::ChatCommand.new({}).execute

      expect(fake_runner).not_to have_received(:run)
    end
  end
end
