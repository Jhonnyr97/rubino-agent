# frozen_string_literal: true

require "tmpdir"
require "fileutils"

RSpec.describe Rubino::CLI::Chat::CompletionBuilder do
  let(:db) { test_database }

  before do
    allow(Rubino).to receive(:database).and_return(db)
    allow(db).to receive(:healthy?).and_return(true)
  end

  # Regression: a previous version did `Commands::BuiltIns::NAMES` from
  # inside Rubino::CLI::ChatCommand. Zeitwerk resolves `Commands` to
  # `Rubino::CLI::Commands` (the Thor class) there, which raises
  # NameError on first interactive boot. #build exercises
  # the real constant resolution.
  describe "#build" do
    it "builds a CompletionSource without raising (Zeitwerk constant resolution)" do
      cmd_loader = Rubino::Commands::Loader.new
      expect do
        described_class.new(cmd_loader).build
      end.not_to raise_error
    end

    it "feeds built-in slash commands into the completion source" do
      cmd_loader = instance_double(Rubino::Commands::Loader, names: [], all: [])
      source = described_class.new(cmd_loader).build
      expect(source.candidates_for("/")).to include("/help", "/exit")
    end

    it "uses a lazy files proc resolving to the workspace primary root" do
      cmd_loader = instance_double(Rubino::Commands::Loader, names: [], all: [])
      source = described_class.new(cmd_loader).build
      files_proc = source.instance_variable_get(:@files_root_proc)
      expect(files_proc.call).to eq(Rubino::Workspace.primary_root)
    end

    # #39: the dropdown carries the same one-liners /help shows, plus the
    # /agents subcommand usage hints, and completes the steer/probe/--stop
    # grammar (ids first) for /agents, /tasks and the /reply blocked ids.
    it "registers the BuiltIns descriptions plus the /agents grammar hints" do
      cmd_loader = instance_double(Rubino::Commands::Loader, names: [], all: [])
      source = described_class.new(cmd_loader).build
      expect(source.description_for("/sessions"))
        .to eq(Rubino::Commands::BuiltIns::DESCRIPTIONS["/sessions"])
      expect(source.description_for("steer")).to include("note")
      expect(source.description_for("--stop")).to include("cancel")
    end

    it "completes the /agents grammar: live ids, then steer/probe/--stop" do
      entry = Rubino::Tools::BackgroundTasks.instance.reserve(subagent: "explore", prompt: "look around")
      cmd_loader = instance_double(Rubino::Commands::Loader, names: [], all: [])
      source = described_class.new(cmd_loader).build

      expect(source.arg_candidates_for("agents", "")).to include(entry.id)
      expect(source.arg_candidates_for("agents", "", [entry.id]))
        .to eq(["steer", "probe", "--stop"])
      expect(source.arg_candidates_for("tasks", "", [entry.id]))
        .to eq(["steer", "probe", "--stop"])
      expect(source.arg_candidates_for("agents", "", [entry.id, "steer"])).to eq([])
    end

    # #182: typing `/mcp ` offers the configured server names + reload; after a
    # server name the on/off verbs complete; reload terminates the grammar.
    it "completes the /mcp grammar: server names + reload, then on/off" do
      raw = { "mcp" => { "servers" => { "filesystem" => { "command" => "x" } } } }
      allow(Rubino).to receive(:configuration).and_return(test_configuration(raw))
      cmd_loader = instance_double(Rubino::Commands::Loader, names: [], all: [])
      source = described_class.new(cmd_loader).build

      expect(source.arg_candidates_for("mcp", "")).to eq(%w[filesystem reload])
      expect(source.arg_candidates_for("mcp", "", ["filesystem"])).to eq(%w[on off])
      expect(source.arg_candidates_for("mcp", "", ["reload"])).to eq([])
      expect(source.arg_candidates_for("mcp", "", %w[filesystem on])).to eq([])
      expect(source.description_for("/mcp")).to include("MCP servers")
      expect(source.description_for("reload")).to include("reconnect")
      expect(source.description_for("off")).to include("stop")
    end

    # #185: the closed enums complete their valid values from the dropdown —
    # previously discoverable only by typing a wrong one and reading the error.
    # No ✗ none entry: "none" is not a mode/render-mode/effort.
    it "completes the /mode, /reasoning and /think enums without a ✗ none entry (#185)" do
      cmd_loader = instance_double(Rubino::Commands::Loader, names: [], all: [])
      source = described_class.new(cmd_loader).build

      expect(source.arg_candidates_for("mode", "")).to eq(%w[default plan yolo])
      expect(source.arg_candidates_for("reasoning", "")).to eq(%w[hidden collapsed full])
      expect(source.arg_candidates_for("think", "")).to eq(%w[off low medium high])
      expect(source.arg_candidates_for("mode", "")).not_to include("✗ none")
      # First argument only — the enums take a single value.
      expect(source.arg_candidates_for("mode", "", ["plan"])).to eq([])
      expect(source.arg_candidates_for("think", "", ["high"])).to eq([])
    end

    it "registers one-line descriptions for the enum values (#185)" do
      cmd_loader = instance_double(Rubino::Commands::Loader, names: [], all: [])
      source = described_class.new(cmd_loader).build

      expect(source.description_for("plan")).to eq(Rubino::Modes.description(:plan))
      expect(source.description_for("collapsed")).to include("Ctrl-O")
      expect(source.description_for("medium")).to include("default")
    end

    # #185: `/add-dir ` completes filesystem DIRECTORIES from the typed
    # partial (the partial-aware source), first argument only.
    it "completes directories for /add-dir from the typed partial (#185)" do
      cmd_loader = instance_double(Rubino::Commands::Loader, names: [], all: [])
      source = described_class.new(cmd_loader).build

      Dir.mktmpdir do |dir|
        FileUtils.mkdir_p(File.join(dir, "sub"))
        File.write(File.join(dir, "subfile.txt"), "x")
        expect(source.arg_candidates_for("add-dir", "#{dir}/su")).to eq(["#{dir}/sub"])
        expect(source.arg_candidates_for("add-dir", "#{dir}/su", ["already"])).to eq([])
      end
    end

    # #183: the /sessions grammar — verbs + recent ids first (bare id
    # resumes), recent ids after show/delete.
    it "completes the /sessions grammar: verbs + recent ids, then ids after a verb (#183)" do
      repo = Rubino::Session::Repository.new(db: db.db)
      repo.create(source: "cli", title: "completable")
      session_id = repo.list(limit: 1).first[:id]

      cmd_loader = instance_double(Rubino::Commands::Loader, names: [], all: [])
      source = described_class.new(cmd_loader).build

      first = source.arg_candidates_for("sessions", "")
      expect(first).to include("show", "delete", "--all", session_id)
      expect(source.arg_candidates_for("sessions", "", ["show"])).to include(session_id)
      expect(source.arg_candidates_for("sessions", "", ["delete"])).to include(session_id)
      expect(source.arg_candidates_for("sessions", "", ["--all"])).to eq([])
      expect(source.arg_candidates_for("sessions", "", ["show", session_id])).to eq([])
    end

    # #184: the /memory grammar — verbs, then fact ids after show/forget and
    # backend names after backend.
    it "completes the /memory grammar: verbs, ids after show/forget, backends after backend (#184)" do
      backend = Rubino::Memory::Backends::Sqlite.new(config: test_configuration, db: db.db)
      allow(Rubino::Memory::Backends).to receive(:build).and_return(backend)
      fact = backend.store(kind: "fact", content: "completable fact")

      cmd_loader = instance_double(Rubino::Commands::Loader, names: [], all: [])
      source = described_class.new(cmd_loader).build

      expect(source.arg_candidates_for("memory", ""))
        .to eq(["search", "show", "forget", "backend", "--all"])
      expect(source.arg_candidates_for("memory", "", ["show"])).to include(fact[:id][0..7])
      expect(source.arg_candidates_for("memory", "", ["forget"])).to include(fact[:id][0..7])
      expect(source.arg_candidates_for("memory", "", ["backend"]))
        .to eq(Rubino::Memory::Backends.names)
      expect(source.arg_candidates_for("memory", "", ["search"])).to eq([])
    end

    # #188: the /skills grammar — `✗ none` + the enable/disable verbs + the
    # skill names first; after a toggle verb the names complete again, so
    # activate-by-name and the clear entry keep working unchanged.
    it "completes the /skills grammar: ✗ none + verbs + names, then names after a verb (#188)" do
      registry = instance_double(Rubino::Skills::Registry, names: %w[ruby-expert data-helper])
      allow(Rubino::Skills::Registry).to receive(:trusted).and_return(registry)

      cmd_loader = instance_double(Rubino::Commands::Loader, names: [], all: [])
      source = described_class.new(cmd_loader).build

      expect(source.arg_candidates_for("skills", ""))
        .to eq(["✗ none", "enable", "disable", "ruby-expert", "data-helper"])
      expect(source.arg_candidates_for("skills", "no")).to eq(["✗ none"])
      expect(source.arg_candidates_for("skills", "", ["enable"])).to eq(%w[ruby-expert data-helper])
      expect(source.arg_candidates_for("skills", "", ["disable"])).to eq(%w[ruby-expert data-helper])
      expect(source.arg_candidates_for("skills", "", ["ruby-expert"])).to eq([])
      expect(source.description_for("disable")).to include("index")
    end

    # #187: /jobs completes recent job ids (short form), first position only.
    it "completes recent job ids for /jobs (#187)" do
      queue = Rubino::Jobs::Queue.new(
        db: db.db, config: test_configuration("jobs" => { "mode" => "manual", "max_attempts" => 3 })
      )
      id = queue.enqueue("DistillSkillJob", { "session_id" => "s1" })
      allow(Rubino::Jobs::Queue).to receive(:new).and_return(queue)

      cmd_loader = instance_double(Rubino::Commands::Loader, names: [], all: [])
      source = described_class.new(cmd_loader).build

      expect(source.arg_candidates_for("jobs", "")).to include(id[0..7])
      expect(source.arg_candidates_for("jobs", "", [id[0..7]])).to eq([])
    end

    # #187: /config completes the verbs + the known keys (the defaults tree
    # flattened to dot-paths), and the keys again after get/set.
    it "completes the /config grammar: verbs + known keys, keys after get/set (#187)" do
      cmd_loader = instance_double(Rubino::Commands::Loader, names: [], all: [])
      source = described_class.new(cmd_loader).build

      first = source.arg_candidates_for("config", "mod")
      expect(first).to include("model.default")
      expect(source.arg_candidates_for("config", "")).to include("get", "set", "show", "path")
      expect(source.arg_candidates_for("config", "memory", ["get"])).to include("memory.backend")
      expect(source.arg_candidates_for("config", "memory", ["set"])).to include("memory.backend")
      expect(source.arg_candidates_for("config", "", ["show"])).to eq([])
      expect(source.arg_candidates_for("config", "", %w[get model.default])).to eq([])
      expect(source.description_for("get")).to include("config")
    end
  end
end
