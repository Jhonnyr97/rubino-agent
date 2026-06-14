# frozen_string_literal: true

# Specs for the OS-sandbox seam (#290). These pin the contract that matters
# for "safe to sit open": DEFAULT resolves to LocalBackend with the exact
# historical argv, and the sandbox only engages when opted in.
RSpec.describe Rubino::Execution::Backend do
  def configure(execution: nil)
    raw = Rubino::Config::Defaults.to_hash
    raw["execution"] = execution if execution
    cfg = Rubino::Config::Configuration.new(raw: raw, home_path: TEST_HOME)
    allow(Rubino).to receive(:configuration).and_return(cfg)
  end

  describe ".argv (DEFAULT)" do
    it "is byte-identical to the historical bash argv" do
      configure
      expect(described_class.argv("echo hi"))
        .to eq(["bash", "-o", "pipefail", "-c", "echo hi"])
    end

    it "ignores the execution key when sandbox is absent/false" do
      configure(execution: { "sandbox" => false, "mode" => "workspace_write" })
      expect(described_class.current).to be_a(Rubino::Execution::LocalBackend)
    end
  end

  describe ".current resolution" do
    it "is LocalBackend by default" do
      configure
      expect(described_class.current).to be_a(Rubino::Execution::LocalBackend)
    end

    it "is SandboxBackend when execution.sandbox is true" do
      configure(execution: { "sandbox" => true, "mode" => "workspace_write" })
      expect(described_class.current).to be_a(Rubino::Execution::SandboxBackend)
    end

    it "stays Local under runtime YOLO even when sandbox is on (escape hatch)" do
      configure(execution: { "sandbox" => true, "mode" => "workspace_write" })
      Rubino::Modes.set(:yolo)
      expect(described_class.current).to be_a(Rubino::Execution::LocalBackend)
    end

    it "maps mode full_access to LocalBackend" do
      configure(execution: { "sandbox" => true, "mode" => "full_access" })
      expect(described_class.current).to be_a(Rubino::Execution::LocalBackend)
    end

    it "defaults an unknown mode to workspace_write" do
      configure(execution: { "sandbox" => true, "mode" => "bogus" })
      expect(described_class.configured_mode).to eq(:workspace_write)
    end
  end
end

RSpec.describe Rubino::Execution::LocalBackend do
  it "returns the exact historical argv and never degrades" do
    backend = described_class.new
    expect(backend.argv("ls -la", writable_roots: ["/x"]))
      .to eq(["bash", "-o", "pipefail", "-c", "ls -la"])
    expect(backend.degraded?).to be(false)
  end
end

RSpec.describe Rubino::Execution::SandboxBackend do
  let(:roots) { ["/work"] }

  before { allow(Rubino).to receive(:home_path).and_return("/home/u/.rubino") }

  def force_os(os) = allow(described_class).to receive(:host_os).and_return(os)

  describe "macOS argv composition" do
    before do
      force_os(:macos)
      allow(described_class).to receive(:available?).and_return(true)
      allow(File).to receive(:write) # don't actually touch disk
      allow(FileUtils).to receive(:mkdir_p)
    end

    it "wraps the inner argv in sandbox-exec -f <profile> --" do
      argv = described_class.new(mode: :workspace_write).argv("echo hi", writable_roots: roots)
      expect(argv[0]).to eq("/usr/bin/sandbox-exec")
      expect(argv[1]).to eq("-f")
      expect(argv[2]).to match(/\.sb\z/)
      expect(argv[3]).to eq("--")
      expect(argv[4..]).to eq(["bash", "-o", "pipefail", "-c", "echo hi"])
    end

    it "generates an SBPL profile: deny default, writable workspace, ro home/.git, deny net" do
      captured = nil
      allow(File).to receive(:write) { |_p, c| captured = c }
      described_class.new(mode: :workspace_write).argv("x", writable_roots: roots)
      expect(captured).to include("(deny default)")
      expect(captured).to include('(allow file-write* (subpath "/work"))')
      expect(captured).to include('(deny file-write* (subpath "/home/u/.rubino"))')
      expect(captured).to include("(deny network*)")
    end

    it "allows network when execution.network is true" do
      allow(Rubino::Execution::Backend).to receive(:network_enabled?).and_return(true)
      captured = nil
      allow(File).to receive(:write) { |_p, c| captured = c }
      described_class.new.argv("x", writable_roots: roots)
      expect(captured).to include("(allow network*)")
    end

    it "writes nothing-writable in :read_only mode" do
      captured = nil
      allow(File).to receive(:write) { |_p, c| captured = c }
      described_class.new(mode: :read_only).argv("x", writable_roots: roots)
      expect(captured).not_to include("(allow file-write* (subpath \"/work\"))")
    end
  end

  describe "Linux argv composition" do
    before do
      force_os(:linux)
      allow(described_class).to receive(:available?).and_return(true)
      allow(File).to receive(:exist?).and_return(true)
    end

    it "wraps the inner argv in bwrap with --ro-bind / and --unshare-net" do
      argv = described_class.new(mode: :workspace_write).argv("echo hi", writable_roots: roots)
      expect(argv.first).to eq("bwrap")
      expect(argv).to include("--ro-bind", "/", "/")
      expect(argv).to include("--unshare-net")
      expect(argv.last(5)).to eq(["bash", "-o", "pipefail", "-c", "echo hi"])
    end

    it "binds the workspace root writable" do
      argv = described_class.new(mode: :workspace_write).argv("x", writable_roots: roots)
      idx = argv.each_index.find { |i| argv[i] == "--bind" && argv[i + 1] == "/work" }
      expect(idx).not_to be_nil
    end

    it "drops --unshare-net when network is enabled" do
      allow(Rubino::Execution::Backend).to receive(:network_enabled?).and_return(true)
      argv = described_class.new.argv("x", writable_roots: roots)
      expect(argv).not_to include("--unshare-net")
    end
  end

  describe "degrade-to-Local" do
    before do
      force_os(:linux)
      allow(described_class).to receive(:available?).and_return(false)
    end

    it "returns the LocalBackend argv unchanged when the mechanism is absent" do
      argv = described_class.new.argv("echo hi", writable_roots: roots)
      expect(argv).to eq(["bash", "-o", "pipefail", "-c", "echo hi"])
    end

    it "emits the degraded warning exactly once" do
      ui = Rubino.ui
      expect(ui).to receive(:warning).once.with(/UNSANDBOXED/)
      backend = described_class.new
      backend.argv("a", writable_roots: roots)
      backend.argv("b", writable_roots: roots) # second call: no second warning
    end

    it "reports degraded? true" do
      expect(described_class.new.degraded?).to be(true)
    end
  end
end
