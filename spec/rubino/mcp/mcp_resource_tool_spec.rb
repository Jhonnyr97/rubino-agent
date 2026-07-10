# frozen_string_literal: true

RSpec.describe Rubino::MCP::McpResourceTool do
  def fake_resource(uri:, name: uri, description: "desc", mime_type: nil, content: nil)
    resource = double("mcp_resource",
                      uri: uri,
                      name: name,
                      description: description,
                      mime_type: mime_type)
    allow(resource).to receive(:content).and_return(content) if content
    resource
  end

  def fake_client(resources, alive: true)
    double("mcp_client", resources: resources, alive?: alive, stop: nil)
  end

  subject(:tool) { described_class.new(client, server_name: server_name) }

  let(:client) { fake_client([]) }
  let(:server_name) { "filesystem" }

  # ── per-server identity ──

  it "includes the server name in the tool name" do
    expect(tool.name).to eq("filesystem_resources")
  end

  it "caps the name at 64 chars" do
    long = "a" * 80
    capped = described_class.new(fake_client([]), server_name: long)
    expect(capped.name.length).to be <= 64
  end

  it "exposes its server via #mcp_server (for the scoping filter)" do
    expect(tool.mcp_server).to eq("filesystem")
  end

  it "responds to #mcp? with true" do
    expect(tool.mcp?).to be(true)
  end

  it "returns 'resources' as bare_name" do
    expect(tool.bare_name).to eq("resources")
  end

  it "formats display_name as 'resources (mcp:<server>)'" do
    expect(tool.display_name).to eq("resources (mcp:filesystem)")
  end

  it "exposes its server via #server_name" do
    expect(tool.server_name).to eq("filesystem")
  end

  it "mentions the specific server in the description" do
    expect(tool.description).to include("filesystem")
    expect(tool.description).to include("list", "read")
  end

  # ── DSL metadata ──

  describe "params schema" do
    it "advertises the action and optional uri params" do
      schema = tool.input_schema
      expect(schema[:required]).to contain_exactly("action")
      expect(schema[:properties].keys).to contain_exactly(:action, :uri)
    end

    it "constrains :action to the valid enum values" do
      schema = tool.input_schema
      expect(schema[:properties][:action][:enum]).to eq(%w[list read])
    end
  end

  describe "class-level security / redaction" do
    it "declares :medium risk with no sandbox" do
      sec = tool.security
      expect(sec).to be_a(described_class::ResourceSecurity)
      expect(sec.risk).to eq(:medium)
      expect(sec.risky?).to be(true)
      expect(sec.sandbox).to eq(:none)
    end

    it "explicitly declares redaction_profile as :shell" do
      expect(described_class.redaction_profile).to eq(:shell)
    end

    it "uses the default ToolPresentationCLI" do
      expect(tool.presentation).to be_a(Rubino::Tools::ToolPresentationCLI)
    end
  end

  # ── execute behaviours ──

  describe "#execute" do
    it "returns an error for an unknown action" do
      result = tool.execute(action: "delete", uri: nil)
      expect(result).to eq('Error: unknown action "delete" — use "list" or "read".')
    end

    # ── list ──

    it "lists only THIS server's resources" do
      tool2 = described_class.new(
        fake_client([fake_resource(uri: "file:///a", name: "A", description: "Alpha")]),
        server_name: "filesystem"
      )

      result = tool2.execute(action: "list", uri: nil)

      expect(result).to include("[filesystem]")
      expect(result).to include("file:///a — A (text) — Alpha")
    end

    it "includes mime_type when present" do
      c = fake_client(
        [fake_resource(uri: "file:///img", name: "img", description: "Pic", mime_type: "image/png")]
      )
      t = described_class.new(c, server_name: "fs")

      result = t.execute(action: "list", uri: nil)

      expect(result).to include("(image/png)")
    end

    it "returns a clear message when this server exposes no resources" do
      result = tool.execute(action: "list", uri: nil)
      expect(result).to eq("No resources exposed by \"filesystem\".")
    end

    it "survives a client whose #resources raises" do
      broken = double("broken_client")
      allow(broken).to receive(:resources).and_raise(StandardError, "boom")
      t = described_class.new(broken, server_name: "broken")

      result = t.execute(action: "list", uri: nil)

      expect(result).to eq("No resources exposed by \"broken\".")
    end

    # ── read ──

    it "returns an error when uri is blank" do
      result = tool.execute(action: "read", uri: "")
      expect(result).to eq('Error: uri is required for "read" action.')
    end

    it "returns an error when uri is nil" do
      result = tool.execute(action: "read", uri: nil)
      expect(result).to eq('Error: uri is required for "read" action.')
    end

    it "returns an error when the uri is not found on THIS server" do
      c = fake_client([fake_resource(uri: "file:///a", name: "A")])
      t = described_class.new(c, server_name: "filesystem")

      result = t.execute(action: "read", uri: "file:///missing")

      expect(result).to eq('Error: no MCP resource found with uri "file:///missing".')
    end

    it "returns the content for a known uri" do
      res = fake_resource(uri: "file:///a", name: "A", content: "hello world")
      c = fake_client([res])
      t = described_class.new(c, server_name: "filesystem")

      result = t.execute(action: "read", uri: "file:///a")

      expect(result).to eq("hello world")
    end

    it "maps a server error during content read to the Error: convention" do
      res = fake_resource(uri: "file:///a", name: "A")
      allow(res).to receive(:content).and_raise(StandardError, "server gone")
      c = fake_client([res])
      t = described_class.new(c, server_name: "filesystem")

      result = t.execute(action: "read", uri: "file:///a")

      expect(result).to eq('Error: MCP resource "file:///a": server gone')
    end

    it "returns an error for empty content" do
      res = fake_resource(uri: "file:///empty", name: "E", content: "")
      c = fake_client([res])
      t = described_class.new(c, server_name: "filesystem")

      result = t.execute(action: "read", uri: "file:///empty")

      expect(result).to eq('Error: resource "file:///empty" returned empty content.')
    end

    it "does NOT reach into other servers (per-server isolation)" do
      # This tool talks to ONE client — no global iteration over managers.
      c = fake_client([fake_resource(uri: "file:///a", name: "A", content: "local")])
      t = described_class.new(c, server_name: "filesystem")

      result = t.execute(action: "read", uri: "file:///a")

      expect(result).to eq("local")
    end
  end
end
