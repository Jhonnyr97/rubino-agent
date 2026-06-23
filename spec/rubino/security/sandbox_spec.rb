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
  def configure(mode:, mechanism:, extra_writable: [], require_sandbox: false)
    raw = Rubino::Config::Defaults.to_hash
    raw["tools"]["sandbox"]["mode"] = mode
    raw["tools"]["sandbox"]["extra_writable"] = extra_writable
    raw["tools"]["sandbox"]["require"] = require_sandbox
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

    it "summarises state for /status with the require/best-effort posture" do
      configure(mode: "workspace-write", mechanism: :landlock)
      expect(described_class.status_summary).to eq("workspace-write (landlock, best-effort)")

      configure(mode: "workspace-write", mechanism: :landlock, require_sandbox: true)
      expect(described_class.status_summary).to eq("workspace-write (landlock, required)")

      configure(mode: "workspace-write", mechanism: :none)
      expect(described_class.status_summary).to eq("OFF (unavailable)")

      configure(mode: "workspace-write", mechanism: :none, require_sandbox: true)
      expect(described_class.status_summary).to eq("OFF (unavailable, required)")
    end
  end

  describe ".active?" do
    it "is true when a mechanism exists and mode != off" do
      configure(mode: "workspace-write", mechanism: :seatbelt)
      expect(described_class).to be_active
    end

    it "is false when mode is off" do
      configure(mode: "off", mechanism: :seatbelt)
      expect(described_class).not_to be_active
    end

    it "is false when degraded (requested but no mechanism)" do
      configure(mode: "workspace-write", mechanism: :none)
      expect(described_class).not_to be_active
    end
  end

  describe ".enforcing? (runtime self-test)" do
    it "is false when not active (no relaxation possible)" do
      configure(mode: "off", mechanism: :seatbelt)
      expect(described_class).not_to be_enforcing
    end

    it "is true when active AND the probe write is DENIED (file absent)" do
      configure(mode: "workspace-write", mechanism: :landlock)
      allow(described_class).to receive(:probe_enforcement).and_return(true)
      expect(described_class).to be_enforcing
      expect(described_class).not_to be_present_but_not_enforcing
    end

    it "is false (DEGRADED) when active but the probe write SUCCEEDED (fails open)" do
      configure(mode: "workspace-write", mechanism: :landlock)
      allow(described_class).to receive(:probe_enforcement).and_return(false)
      expect(described_class).not_to be_enforcing
      expect(described_class).to be_present_but_not_enforcing
    end

    it "memoises the probe (one spawn per process)" do
      configure(mode: "workspace-write", mechanism: :landlock)
      allow(described_class).to receive(:probe_enforcement).and_return(true)
      2.times { described_class.enforcing? }
      expect(described_class).to have_received(:probe_enforcement).once
    end
  end

  describe ".wrap_argv / .wrap_env" do
    it "prepends the launcher prefix to an arbitrary argv" do
      configure(mode: "workspace-write", mechanism: :landlock)
      allow(described_class).to receive(:landlock_helper).and_return("/h/rubino-landlock")
      argv = described_class.wrap_argv(%w[ruby -e 1], cwd: workspace)
      expect(argv).to eq(["/h/rubino-landlock", "--", "ruby", "-e", "1"])
    end

    it "is a no-op (identity argv) when off/unavailable" do
      configure(mode: "workspace-write", mechanism: :none)
      expect(described_class.wrap_argv(%w[ruby -e 1], cwd: workspace)).to eq(%w[ruby -e 1])
      expect(described_class.wrap_env(cwd: workspace)).to eq({})
    end

    it "carries the writable roots env for Landlock" do
      configure(mode: "workspace-write", mechanism: :landlock)
      allow(described_class).to receive(:landlock_helper).and_return("/h/rubino-landlock")
      expect(described_class.wrap_env(cwd: workspace)).to have_key("RUBINO_SANDBOX_WRITABLE_ROOTS")
    end
  end

  # #74: an EACCES from the OS write-jail (a write OUTSIDE the writable roots)
  # reads like an ordinary perms error; the model retries with chmod/sudo. When
  # the jail is enforcing AND the denied path is outside the writable set, append
  # a clear attribution so the model writes inside the workspace instead.
  describe ".write_jail_attribution" do
    before do
      configure(mode: "workspace-write", mechanism: :landlock)
      allow(described_class).to receive(:probe_enforcement).and_return(true)
    end

    it "attributes an EACCES against a path OUTSIDE the writable roots to the jail" do
      text = "bash: line 1: /usr/local/blocked.txt: Permission denied"
      hint = described_class.write_jail_attribution(text, cwd: workspace)
      expect(hint).to include("write-jail")
      expect(hint).to include("tools.sandbox")
    end

    it "does NOT attribute a normal perms error INSIDE the workspace to the jail" do
      inside = File.join(File.realpath(workspace), "locked.txt")
      text = "open #{inside}: Permission denied"
      expect(described_class.write_jail_attribution(text, cwd: workspace)).to be_nil
    end

    it "is nil when the jail is NOT enforcing (no misattribution on an open host)" do
      allow(described_class).to receive(:probe_enforcement).and_return(false)
      text = "/usr/local/blocked.txt: Permission denied"
      expect(described_class.write_jail_attribution(text, cwd: workspace)).to be_nil
    end

    it "is nil when there is no EACCES in the output" do
      expect(described_class.write_jail_attribution("all good\n", cwd: workspace)).to be_nil
    end
  end

  describe ".required? and .refusal_reason (fail-closed)" do
    it "does not require by default" do
      configure(mode: "workspace-write", mechanism: :none)
      expect(described_class).not_to be_required
      expect(described_class.refusal_reason).to be_nil
    end

    it "refuses when require:true AND no mechanism is available" do
      configure(mode: "workspace-write", mechanism: :none, require_sandbox: true)
      expect(described_class).to be_required
      expect(described_class.refusal_reason).to include("sandbox required but unavailable")
    end

    it "runs (nil refusal) when require:true but a mechanism IS available" do
      configure(mode: "workspace-write", mechanism: :seatbelt, require_sandbox: true)
      expect(described_class.refusal_reason).to be_nil
    end
  end
end
