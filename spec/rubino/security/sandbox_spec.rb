# frozen_string_literal: true

RSpec.describe Rubino::Security::Sandbox do
  let(:workspace) { Dir.mktmpdir("sandbox-ws") }
  let(:sibling)   { Dir.mktmpdir("sandbox-sibling") }

  before do
    described_class.reset!
    allow(Rubino::Workspace).to receive(:canonical_roots)
      .and_return([File.realpath(workspace)])
    allow(Rubino).to receive(:home_path).and_return(File.realpath(Dir.tmpdir))
  end

  after do
    described_class.reset!
    FileUtils.remove_entry(workspace) if File.directory?(workspace)
    FileUtils.remove_entry(sibling)   if File.directory?(sibling)
  end

  # Drive a deterministic config + mechanism regardless of the host OS.
  def configure(mode:, mechanism:, extra_writable: [])
    raw = Rubino::Config::Defaults.to_hash
    raw["tools"]["sandbox"]["mode"] = mode
    raw["tools"]["sandbox"]["extra_writable"] = extra_writable
    config = Rubino::Config::Configuration.new(raw: raw)
    allow(Rubino).to receive(:configuration).and_return(config)
    allow(described_class).to receive(:available_mechanism).and_return(mechanism)
  end

  describe ".command_prefix" do
    it "is empty when mode is off" do
      configure(mode: "off", mechanism: :seatbelt)
      expect(described_class.command_prefix(cwd: workspace)).to eq([])
    end

    it "is empty (fail-open) when no mechanism is available" do
      configure(mode: "workspace-write", mechanism: :none)
      expect(described_class.command_prefix(cwd: workspace)).to eq([])
    end

    it "builds the sandbox-exec argv with -D writable roots on macOS/Seatbelt" do
      configure(mode: "workspace-write", mechanism: :seatbelt)
      prefix = described_class.command_prefix(cwd: workspace)

      expect(prefix.first).to eq("/usr/bin/sandbox-exec")
      expect(prefix).to include("-p")
      expect(prefix.last).to eq("--")
      expect(prefix).to include("-DWRITABLE_ROOT_0=#{File.realpath(workspace)}")

      policy = prefix[prefix.index("-p") + 1]
      expect(policy).to include("(deny default)")
      expect(policy).to include("(allow file-read*)")        # reads broad (#406)
      expect(policy).to include("(allow network*)")          # slice-1 network open
      expect(policy).to include('(subpath (param "WRITABLE_ROOT_0"))')
    end

    it "returns [helper, --] on Linux/Landlock" do
      configure(mode: "workspace-write", mechanism: :landlock)
      allow(described_class).to receive(:landlock_helper).and_return("/h/rubino-landlock")
      expect(described_class.command_prefix(cwd: workspace)).to eq(["/h/rubino-landlock", "--"])
    end
  end

  describe ".extra_env" do
    it "passes newline-joined writable roots to the Landlock helper" do
      configure(mode: "workspace-write", mechanism: :landlock)
      env = described_class.extra_env(cwd: workspace)
      roots = env.fetch("RUBINO_SANDBOX_WRITABLE_ROOTS").split("\n")
      expect(roots).to include(File.realpath(workspace))
    end

    it "is empty for Seatbelt (roots go via -D params)" do
      configure(mode: "workspace-write", mechanism: :seatbelt)
      expect(described_class.extra_env(cwd: workspace)).to eq({})
    end

    it "is empty when off" do
      configure(mode: "off", mechanism: :landlock)
      expect(described_class.extra_env(cwd: workspace)).to eq({})
    end
  end

  describe ".writable_roots" do
    it "includes the workspace and temp but not a sibling dir" do
      configure(mode: "workspace-write", mechanism: :landlock)
      roots = described_class.writable_roots(cwd: workspace)

      expect(roots).to include(File.realpath(workspace))
      expect(roots).to include(File.realpath(Dir.tmpdir))
      expect(roots).not_to include(File.realpath(sibling))
    end

    it "EXCLUDES the agent home (~/.rubino): it holds the sandbox trust anchors" do
      home = File.realpath(Dir.mktmpdir("sandbox-home"))
      allow(Rubino).to receive(:home_path).and_return(home)
      configure(mode: "workspace-write", mechanism: :landlock)

      expect(described_class.writable_roots(cwd: workspace)).not_to include(home)
    ensure
      FileUtils.remove_entry(home) if home && File.directory?(home)
    end

    it "honors extra_writable absolute paths" do
      configure(mode: "workspace-write", mechanism: :landlock, extra_writable: [sibling])
      expect(described_class.writable_roots(cwd: workspace)).to include(File.realpath(sibling))
    end

    it "excludes the workspace itself in read-only mode" do
      configure(mode: "read-only", mechanism: :landlock)
      roots = described_class.writable_roots(cwd: workspace)
      expect(roots).not_to include(File.realpath(workspace))
      expect(roots).to include(File.realpath(Dir.tmpdir)) # temp stays writable
    end
  end

  describe "Landlock helper resolution (trust anchor)" do
    # The helper is the trust anchor the jail execs; it must come ONLY from the
    # gem's installed extension build dir, never a ~/.rubino cache the confined
    # shell could overwrite (the cached-helper-poisoning escape, R1).
    let(:built) do
      lib_dir = File.dirname(described_class.method(:reset!).source_location.first)
      File.expand_path("../../../ext/landlock/rubino-landlock", lib_dir)
    end

    it "resolves to the gem's ext/landlock build when it is executable" do
      allow(File).to receive(:executable?).and_call_original
      allow(File).to receive(:executable?).with(built).and_return(true)
      expect(described_class.send(:resolve_landlock_helper)).to eq(built)
    end

    it "does NOT fall back to a writable ~/.rubino/bin cache (returns nil)" do
      home = File.realpath(Dir.mktmpdir("sandbox-home"))
      allow(Rubino).to receive(:home_path).and_return(home)
      FileUtils.mkdir_p(File.join(home, "bin"))
      cache = File.join(home, "bin", "rubino-landlock")
      File.write(cache, "#!/bin/sh\nexec \"$@\"\n")
      File.chmod(0o755, cache)

      allow(File).to receive(:executable?).and_call_original
      allow(File).to receive(:executable?).with(built).and_return(false)

      expect(described_class.send(:resolve_landlock_helper)).to be_nil
    ensure
      FileUtils.remove_entry(home) if home && File.directory?(home)
    end
  end

  describe ".mode and degradation" do
    it "reports the configured mode when a mechanism exists" do
      configure(mode: "workspace-write", mechanism: :seatbelt)
      expect(described_class.mode).to eq(:"workspace-write")
      expect(described_class).not_to be_degraded
      expect(described_class.degradation_notice).to be_nil
    end

    it "falls back to off and flags degraded when no mechanism exists" do
      configure(mode: "workspace-write", mechanism: :none)
      expect(described_class.mode).to eq(:off)
      expect(described_class).to be_degraded
      expect(described_class.degradation_notice).to include("NOT OS-confined")
    end

    it "is not degraded when the user explicitly turns it off" do
      configure(mode: "off", mechanism: :none)
      expect(described_class).not_to be_degraded
    end

    it "summarises state for /status" do
      configure(mode: "workspace-write", mechanism: :landlock)
      expect(described_class.status_summary).to eq("workspace-write (landlock)")

      configure(mode: "workspace-write", mechanism: :none)
      expect(described_class.status_summary).to eq("OFF (unavailable)")
    end
  end
end
