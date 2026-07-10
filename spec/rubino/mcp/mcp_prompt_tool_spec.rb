# frozen_string_literal: true

RSpec.describe Rubino::MCP::McpPromptTool do
  def fake_prompt_argument(name:, description: "arg desc", required: false)
    double("prompt_argument", name: name, description: description, required: required)
  end

  def fake_prompt(name: "greet", description: "A greeting prompt", arguments: [])
    double("mcp_prompt",
           name: name,
           description: description,
           arguments: arguments)
  end

  def fake_client(prompts, alive: true)
    double("mcp_client", prompts: prompts, alive?: alive, stop: nil)
  end

  subject(:tool) { described_class.new(client, server_name: server_name) }

  let(:client) { fake_client([]) }
  let(:server_name) { "filesystem" }

  # ── per-server identity ──

  it "includes the server name in the tool name" do
    expect(tool.name).to eq("filesystem_prompts")
  end

  it "caps the name at 64 chars" do
    long = "a" * 80
    capped = described_class.new(fake_client([]), server_name: long)
    expect(capped.name.length).to be <= 64
  end

  it "exposes its server via #mcp_server (for the scoping filter)" do
    expect(tool.mcp_server).to eq("filesystem")
  end

  it "exposes its server via #server_name" do
    expect(tool.server_name).to eq("filesystem")
  end

  it "mentions the specific server in the description" do
    expect(tool.description).to include("filesystem")
    expect(tool.description).to include("list", "get")
  end

  # ── DSL metadata ──

  describe "params schema" do
    it "advertises the action and optional name/arguments params" do
      schema = tool.input_schema
      expect(schema[:required]).to contain_exactly("action")
      expect(schema[:properties].keys).to contain_exactly(:action, :name, :arguments)
    end

    it "constrains :action to the valid enum values" do
      schema = tool.input_schema
      expect(schema[:properties][:action][:enum]).to eq(%w[list get])
    end

    it "declares :arguments as an object with additionalProperties: true" do
      schema = tool.input_schema
      args = schema[:properties][:arguments]
      expect(args[:type]).to eq("object")
      expect(args[:additionalProperties]).to be(true)
    end
  end

  describe "class-level security / redaction" do
    it "declares :medium risk with no sandbox" do
      sec = tool.security
      expect(sec).to be_a(described_class::PromptSecurity)
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
      result = tool.execute(action: "delete", name: nil)
      expect(result).to eq('Error: unknown action "delete" — use "list" or "get".')
    end

    # ── list ──

    it "lists only THIS server's prompts" do
      prompt = fake_prompt(name: "greet", description: "Hello prompt")
      t = described_class.new(
        fake_client([prompt]),
        server_name: "filesystem"
      )

      result = t.execute(action: "list", name: nil)

      expect(result).to include("[filesystem]")
      expect(result).to include("greet — Hello prompt (args: no args)")
    end

    it "includes argument names and marks optional args with '?'" do
      arg = fake_prompt_argument(name: "name", required: false)
      prompt = fake_prompt(name: "greet", description: "Hello", arguments: [arg])
      t = described_class.new(fake_client([prompt]), server_name: "fs")

      result = t.execute(action: "list", name: nil)

      expect(result).to include("name?")
      expect(result).to include("(args: name?)")
    end

    it "does not mark required args with '?'" do
      arg = fake_prompt_argument(name: "name", required: true)
      prompt = fake_prompt(name: "greet", arguments: [arg])
      t = described_class.new(fake_client([prompt]), server_name: "fs")

      result = t.execute(action: "list", name: nil)

      expect(result).to include("(args: name)")
      expect(result).not_to include("name?")
    end

    it "returns a clear message when this server exposes no prompts" do
      result = tool.execute(action: "list", name: nil)
      expect(result).to eq("No prompts exposed by \"filesystem\".")
    end

    it "survives a client whose #prompts raises" do
      broken = double("broken_client")
      allow(broken).to receive(:prompts).and_raise(StandardError, "boom")
      t = described_class.new(broken, server_name: "broken")

      result = t.execute(action: "list", name: nil)

      expect(result).to eq("No prompts exposed by \"broken\".")
    end

    # ── get ──

    it "returns an error when name is blank" do
      result = tool.execute(action: "get", name: "")
      expect(result).to eq('Error: name is required for "get" action.')
    end

    it "returns an error when name is nil" do
      result = tool.execute(action: "get", name: nil)
      expect(result).to eq('Error: name is required for "get" action.')
    end

    it "returns an error when the prompt is not found on THIS server" do
      prompt = fake_prompt(name: "greet")
      c = fake_client([prompt])
      t = described_class.new(c, server_name: "filesystem")

      result = t.execute(action: "get", name: "missing")

      expect(result).to eq(
        'Error: no MCP prompt found with name "missing" on server "filesystem".'
      )
    end

    it "returns rendered messages for a known prompt" do
      prompt = fake_prompt(name: "greet")
      msg = double("message", role: "user", content: "Hello, World!")
      allow(prompt).to receive(:fetch).with({}).and_return([msg])
      c = fake_client([prompt])
      t = described_class.new(c, server_name: "filesystem")

      result = t.execute(action: "get", name: "greet")

      expect(result).to eq("user: Hello, World!")
    end

    it "passes arguments to prompt.fetch" do
      prompt = fake_prompt(name: "greet")
      msg = double("message", role: "assistant", content: "Hi Alice!")
      allow(prompt).to receive(:fetch).with({ "name" => "Alice" }).and_return([msg])
      c = fake_client([prompt])
      t = described_class.new(c, server_name: "fs")

      result = t.execute(action: "get", name: "greet", arguments: { "name" => "Alice" })

      expect(prompt).to have_received(:fetch).with({ "name" => "Alice" })
      expect(result).to eq("assistant: Hi Alice!")
    end

    it "maps a server error during prompt fetch to the Error: convention" do
      prompt = fake_prompt(name: "greet")
      allow(prompt).to receive(:fetch).and_raise(StandardError, "server gone")
      c = fake_client([prompt])
      t = described_class.new(c, server_name: "filesystem")

      result = t.execute(action: "get", name: "greet")

      expect(result).to eq('Error: MCP prompt "greet": server gone')
    end

    it "does NOT reach into other servers (per-server isolation)" do
      prompt = fake_prompt(name: "greet")
      msg = double("message", role: "user", content: "local")
      allow(prompt).to receive(:fetch).with({}).and_return([msg])
      c = fake_client([prompt])
      t = described_class.new(c, server_name: "filesystem")

      result = t.execute(action: "get", name: "greet")

      expect(result).to eq("user: local")
    end
  end
end
