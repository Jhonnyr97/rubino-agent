# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rubino::Agent::MarkdownLoader do
  let(:registry) { Rubino::Agent::AgentRegistry.new(load_file_agents: false) }

  def write_agent(dir, name, frontmatter = {}, body = "You are a helpful agent.")
    defaults = { "name" => name, "description" => "#{name} agent" }
    meta = defaults.merge(frontmatter)
    yaml = meta.map { |k, v| "#{k}: #{v}" }.join("\n")
    content = "---\n#{yaml}\n---\n#{body}"
    File.write(File.join(dir, "#{name}.md"), content)
  end

  # ------------------------------------------------------------------
  # Basic parsing
  # ------------------------------------------------------------------

  describe "loading a single agent file" do
    it "parses name, description, and body into a Definition" do
      Dir.mktmpdir do |tmp|
        agents_dir = File.join(tmp, ".rubino", "agents")
        FileUtils.mkdir_p(agents_dir)
        write_agent(agents_dir, "my-agent",
                    { "name" => "my-agent", "description" => "Does things" },
                    "You do things carefully.")

        allow(File).to receive(:expand_path).and_call_original
        loader = described_class.new(registry: registry,
                                     include_project_local: true)
        # Override scan dirs to just our tmp dir
        allow(loader).to receive(:scan_dirs).and_return([agents_dir])
        loader.load!

        defn = registry.find("my-agent")
        expect(defn).not_to be_nil
        expect(defn.name).to eq("my-agent")
        expect(defn.description).to eq("Does things")
        expect(defn.system_prompt).to eq("You do things carefully.")
        expect(defn.type).to eq(:subagent) # default
      end
    end

    it "defaults to :subagent type" do
      Dir.mktmpdir do |tmp|
        dir = File.join(tmp, "agents")
        FileUtils.mkdir_p(dir)
        write_agent(dir, "worker", { "name" => "worker", "description" => "w" }, "body")

        loader = described_class.new(registry: registry, include_project_local: true)
        allow(loader).to receive(:scan_dirs).and_return([dir])
        loader.load!

        expect(registry.find("worker").type).to eq(:subagent)
      end
    end

    it "respects explicit type: primary" do
      Dir.mktmpdir do |tmp|
        dir = File.join(tmp, "agents")
        FileUtils.mkdir_p(dir)
        write_agent(dir, "main-agent",
                    { "name" => "main-agent", "description" => "m", "type" => "primary" },
                    "body")

        loader = described_class.new(registry: registry, include_project_local: true)
        allow(loader).to receive(:scan_dirs).and_return([dir])
        loader.load!

        expect(registry.find("main-agent").type).to eq(:primary)
      end
    end
  end

  # ------------------------------------------------------------------
  # Model alias translation
  # ------------------------------------------------------------------

  describe "model aliases" do
    it "maps sonnet → claude-sonnet-4-5" do
      Dir.mktmpdir do |tmp|
        dir = File.join(tmp, "agents")
        FileUtils.mkdir_p(dir)
        write_agent(dir, "sonnet-agent",
                    { "name" => "sonnet-agent", "description" => "s", "model" => "sonnet" },
                    "body")

        loader = described_class.new(registry: registry, include_project_local: true)
        allow(loader).to receive(:scan_dirs).and_return([dir])
        loader.load!

        expect(registry.find("sonnet-agent").model).to eq("claude-sonnet-4-5")
      end
    end

    it "maps opus → claude-opus-4-5" do
      Dir.mktmpdir do |tmp|
        dir = File.join(tmp, "agents")
        FileUtils.mkdir_p(dir)
        write_agent(dir, "opus-agent",
                    { "name" => "opus-agent", "description" => "o", "model" => "opus" },
                    "body")

        loader = described_class.new(registry: registry, include_project_local: true)
        allow(loader).to receive(:scan_dirs).and_return([dir])
        loader.load!

        expect(registry.find("opus-agent").model).to eq("claude-opus-4-5")
      end
    end

    it "maps haiku → claude-haiku-4-5" do
      Dir.mktmpdir do |tmp|
        dir = File.join(tmp, "agents")
        FileUtils.mkdir_p(dir)
        write_agent(dir, "haiku-agent",
                    { "name" => "haiku-agent", "description" => "h", "model" => "haiku" },
                    "body")

        loader = described_class.new(registry: registry, include_project_local: true)
        allow(loader).to receive(:scan_dirs).and_return([dir])
        loader.load!

        expect(registry.find("haiku-agent").model).to eq("claude-haiku-4-5")
      end
    end

    it "maps inherit → nil (use global default)" do
      Dir.mktmpdir do |tmp|
        dir = File.join(tmp, "agents")
        FileUtils.mkdir_p(dir)
        write_agent(dir, "inherit-agent",
                    { "name" => "inherit-agent", "description" => "i", "model" => "inherit" },
                    "body")

        loader = described_class.new(registry: registry, include_project_local: true)
        allow(loader).to receive(:scan_dirs).and_return([dir])
        loader.load!

        expect(registry.find("inherit-agent").model).to be_nil
      end
    end

    it "passes through full model IDs unchanged" do
      Dir.mktmpdir do |tmp|
        dir = File.join(tmp, "agents")
        FileUtils.mkdir_p(dir)
        write_agent(dir, "custom-agent",
                    { "name" => "custom-agent", "description" => "c",
                      "model" => "gpt-4.1" },
                    "body")

        loader = described_class.new(registry: registry, include_project_local: true)
        allow(loader).to receive(:scan_dirs).and_return([dir])
        loader.load!

        expect(registry.find("custom-agent").model).to eq("gpt-4.1")
      end
    end
  end

  # ------------------------------------------------------------------
  # Tool translation
  # ------------------------------------------------------------------

  describe "tool translation" do
    it "translates Claude Code tool names to rubino names" do
      Dir.mktmpdir do |tmp|
        dir = File.join(tmp, "agents")
        FileUtils.mkdir_p(dir)
        write_agent(dir, "tool-agent",
                    { "name" => "tool-agent", "description" => "t",
                      "tools" => "Bash Read Write Grep Glob Edit" },
                    "body")

        loader = described_class.new(registry: registry, include_project_local: true)
        allow(loader).to receive(:scan_dirs).and_return([dir])
        loader.load!

        tools = registry.find("tool-agent").tools
        expect(tools).to contain_exactly("shell", "read", "write", "grep", "glob", "edit")
      end
    end

    it "translates comma-separated tool list" do
      Dir.mktmpdir do |tmp|
        dir = File.join(tmp, "agents")
        FileUtils.mkdir_p(dir)
        write_agent(dir, "comma-agent",
                    { "name" => "comma-agent", "description" => "c",
                      "tools" => "Bash,Read,Write" },
                    "body")

        loader = described_class.new(registry: registry, include_project_local: true)
        allow(loader).to receive(:scan_dirs).and_return([dir])
        loader.load!

        expect(registry.find("comma-agent").tools).to contain_exactly("shell", "read", "write")
      end
    end

    it "warns and drops unknown tool names" do
      Dir.mktmpdir do |tmp|
        dir = File.join(tmp, "agents")
        FileUtils.mkdir_p(dir)
        write_agent(dir, "unknown-tool",
                    { "name" => "unknown-tool", "description" => "u",
                      "tools" => "Bash NonExistentTool AnotherFake" },
                    "body")

        loader = described_class.new(registry: registry, include_project_local: true)
        allow(loader).to receive(:scan_dirs).and_return([dir])

        log_io = StringIO.new
        Rubino.logger = Rubino::Logger.new(io: log_io)
        loader.load!
        logged = log_io.string
        expect(logged).to include("agent.md.unknown_tool")
        expect(logged).to include("NonExistentTool")
        expect(logged).to include("AnotherFake")

        expect(registry.find("unknown-tool").tools).to contain_exactly("shell")
      end
    end

    it "defaults to :all when tools field is empty" do
      Dir.mktmpdir do |tmp|
        dir = File.join(tmp, "agents")
        FileUtils.mkdir_p(dir)
        write_agent(dir, "all-tools",
                    { "name" => "all-tools", "description" => "a" },
                    "body")

        loader = described_class.new(registry: registry, include_project_local: true)
        allow(loader).to receive(:scan_dirs).and_return([dir])
        loader.load!

        expect(registry.find("all-tools").tools).to eq(:all)
      end
    end
  end

  # ------------------------------------------------------------------
  # disallowedTools → permissions deny entries
  # ------------------------------------------------------------------

  describe "disallowedTools → permissions" do
    it "maps disallowedTools to deny permission rules" do
      Dir.mktmpdir do |tmp|
        dir = File.join(tmp, "agents")
        FileUtils.mkdir_p(dir)
        write_agent(dir, "restricted",
                    { "name" => "restricted", "description" => "r",
                      "disallowedTools" => "Bash Edit" },
                    "body")

        loader = described_class.new(registry: registry, include_project_local: true)
        allow(loader).to receive(:scan_dirs).and_return([dir])
        loader.load!

        perms = registry.find("restricted").permissions
        expect(perms).to eq({ "shell *" => "deny", "edit *" => "deny" })
      end
    end

    it "warns when disallowedTools name cannot be mapped" do
      Dir.mktmpdir do |tmp|
        dir = File.join(tmp, "agents")
        FileUtils.mkdir_p(dir)
        write_agent(dir, "bad-deny",
                    { "name" => "bad-deny", "description" => "b",
                      "disallowedTools" => "NonExistentTool" },
                    "body")

        loader = described_class.new(registry: registry, include_project_local: true)
        allow(loader).to receive(:scan_dirs).and_return([dir])

        log_io = StringIO.new
        Rubino.logger = Rubino::Logger.new(io: log_io)
        loader.load!
        expect(log_io.string).to include("agent.md.unknown_deny_tool")
        expect(log_io.string).to include("NonExistentTool")
      end
    end
  end

  # ------------------------------------------------------------------
  # permissionMode
  # ------------------------------------------------------------------

  describe "permissionMode" do
    it "warns about bypassPermissions having no rubino equivalent" do
      Dir.mktmpdir do |tmp|
        dir = File.join(tmp, "agents")
        FileUtils.mkdir_p(dir)
        write_agent(dir, "bypasser",
                    { "name" => "bypasser", "description" => "b",
                      "permissionMode" => "bypassPermissions" },
                    "body")

        loader = described_class.new(registry: registry, include_project_local: true)
        allow(loader).to receive(:scan_dirs).and_return([dir])

        log_io = StringIO.new
        Rubino.logger = Rubino::Logger.new(io: log_io)
        loader.load!
        expect(log_io.string).to include("agent.md.bypass_permissions")

        # Agent still loads — bypassPermissions is just a no-op
        expect(registry.find("bypasser")).not_to be_nil
      end
    end
  end

  # ------------------------------------------------------------------
  # mcpServers
  # ------------------------------------------------------------------

  describe "mcpServers" do
    it "maps mcpServers string to mcp_servers array" do
      Dir.mktmpdir do |tmp|
        dir = File.join(tmp, "agents")
        FileUtils.mkdir_p(dir)
        write_agent(dir, "mcp-agent",
                    { "name" => "mcp-agent", "description" => "m",
                      "mcpServers" => "github filesystem" },
                    "body")

        loader = described_class.new(registry: registry, include_project_local: true)
        allow(loader).to receive(:scan_dirs).and_return([dir])
        loader.load!

        expect(registry.find("mcp-agent").mcp_servers).to contain_exactly("github", "filesystem")
      end
    end
  end

  # ------------------------------------------------------------------
  # maxTurns
  # ------------------------------------------------------------------

  describe "maxTurns" do
    it "maps maxTurns to max_turns" do
      Dir.mktmpdir do |tmp|
        dir = File.join(tmp, "agents")
        FileUtils.mkdir_p(dir)
        write_agent(dir, "limited",
                    { "name" => "limited", "description" => "l", "maxTurns" => 15 },
                    "body")

        loader = described_class.new(registry: registry, include_project_local: true)
        allow(loader).to receive(:scan_dirs).and_return([dir])
        loader.load!

        expect(registry.find("limited").max_turns).to eq(15)
      end
    end

    it "falls back to global config when maxTurns absent" do
      Dir.mktmpdir do |tmp|
        dir = File.join(tmp, "agents")
        FileUtils.mkdir_p(dir)
        write_agent(dir, "unlimited",
                    { "name" => "unlimited", "description" => "u" },
                    "body")

        loader = described_class.new(registry: registry, include_project_local: true)
        allow(loader).to receive(:scan_dirs).and_return([dir])
        loader.load!

        # Definition#max_turns falls back to Rubino.configuration.dig("agent", "max_turns")
        # when @max_turns is nil — the global default (shipped as 90).
        expect(registry.find("unlimited").max_turns).to be_a(Integer)
      end
    end
  end

  # ------------------------------------------------------------------
  # Ignored fields
  # ------------------------------------------------------------------

  describe "ignored fields" do
    it "logs unsupported fields at debug without rejecting the agent" do
      Dir.mktmpdir do |tmp|
        dir = File.join(tmp, "agents")
        FileUtils.mkdir_p(dir)
        write_agent(dir, "fancy",
                    { "name" => "fancy", "description" => "f",
                      "color" => "blue", "effort" => "high" },
                    "body")

        loader = described_class.new(registry: registry, include_project_local: true)
        allow(loader).to receive(:scan_dirs).and_return([dir])

        log_io = StringIO.new
        Rubino.logger = Rubino::Logger.new(io: log_io, level: "debug")
        loader.load!
        expect(log_io.string).to include("agent.md.ignored_field")
        expect(log_io.string).to include("color")
        expect(log_io.string).to include("effort")

        expect(registry.find("fancy")).not_to be_nil
      end
    end
  end

  # ------------------------------------------------------------------
  # Directory discovery
  # ------------------------------------------------------------------

  describe "discovery paths" do
    it "discovers agents from ~/.claude/agents (user-level)" do
      Dir.mktmpdir do |tmp|
        claude_dir = File.join(tmp, ".claude", "agents")
        FileUtils.mkdir_p(claude_dir)
        write_agent(claude_dir, "claude-agent",
                    { "name" => "claude-agent", "description" => "c" }, "body")

        # Simulate home = tmp so ~/.claude/agents resolves correctly
        allow(Dir).to receive(:home).and_return(tmp)
        loader = described_class.new(registry: registry, include_project_local: true)
        allow(loader).to receive(:scan_dirs).and_return([claude_dir])
        loader.load!

        expect(registry.find("claude-agent")).not_to be_nil
      end
    end

    it "discovers agents from ~/.rubino/agents (user-level)" do
      Dir.mktmpdir do |tmp|
        rubino_dir = File.join(tmp, ".rubino", "agents")
        FileUtils.mkdir_p(rubino_dir)
        write_agent(rubino_dir, "rubino-agent",
                    { "name" => "rubino-agent", "description" => "r" }, "body")

        loader = described_class.new(registry: registry, include_project_local: true)
        allow(loader).to receive(:scan_dirs).and_return([rubino_dir])
        loader.load!

        expect(registry.find("rubino-agent")).not_to be_nil
      end
    end
  end

  # ------------------------------------------------------------------
  # Precedence: project overrides user
  # ------------------------------------------------------------------

  describe "precedence" do
    it "project-local agent overrides user-level agent of the same name" do
      Dir.mktmpdir do |tmp|
        user_dir = File.join(tmp, "user", "agents")
        FileUtils.mkdir_p(user_dir)
        write_agent(user_dir, "shared",
                    { "name" => "shared", "description" => "user version" },
                    "user body")

        proj_dir = File.join(tmp, "project", "agents")
        FileUtils.mkdir_p(proj_dir)
        write_agent(proj_dir, "shared",
                    { "name" => "shared", "description" => "project version" },
                    "project body")

        loader = described_class.new(registry: registry, include_project_local: true)
        # Simulate scan order: user first, project second
        allow(loader).to receive(:scan_dirs).and_return([user_dir, proj_dir])
        loader.load!

        defn = registry.find("shared")
        expect(defn.description).to eq("project version")
        expect(defn.system_prompt).to eq("project body")
      end
    end
  end

  # ------------------------------------------------------------------
  # Built-in name collision: file agent replaces built-in
  # ------------------------------------------------------------------

  describe "built-in override" do
    it "file-defined agent replaces a built-in of the same name" do
      Dir.mktmpdir do |tmp|
        dir = File.join(tmp, "agents")
        FileUtils.mkdir_p(dir)
        write_agent(dir, "general",
                    { "name" => "general", "description" => "custom general",
                      "model" => "sonnet", "maxTurns" => 25 },
                    "custom body")

        # Register built-ins first
        registry # triggers register_defaults! (load_file_agents: false)
        builtin = registry.find("general")
        expect(builtin.description).to eq("General-purpose agent for complex multi-step tasks")

        # Then load file agents
        loader = described_class.new(registry: registry, include_project_local: true)
        allow(loader).to receive(:scan_dirs).and_return([dir])
        loader.load!

        overridden = registry.find("general")
        expect(overridden.description).to eq("custom general")
        expect(overridden.system_prompt).to eq("custom body")
        expect(overridden.model).to eq("claude-sonnet-4-5")
        expect(overridden.max_turns).to eq(25)
      end
    end
  end

  # ------------------------------------------------------------------
  # Trust-gating
  # ------------------------------------------------------------------

  describe "trust-gating" do
    it "loads project-local agents when trusted" do
      Dir.mktmpdir do |tmp|
        project = File.realpath(tmp)
        agents_dir = File.join(project, ".rubino", "agents")
        FileUtils.mkdir_p(agents_dir)
        write_agent(agents_dir, "trusted-agent",
                    { "name" => "trusted-agent", "description" => "t" }, "body")

        allow(Rubino::Workspace).to receive(:primary_root).and_return(project)
        Dir.chdir(project) do
          loader = described_class.new(registry: registry,
                                       include_project_local: true)
          loader.load!

          expect(registry.find("trusted-agent")).not_to be_nil
        end
      end
    end

    it "skips project-local agents when untrusted" do
      Dir.mktmpdir do |tmp|
        project = File.realpath(tmp)
        agents_dir = File.join(project, ".rubino", "agents")
        FileUtils.mkdir_p(agents_dir)
        write_agent(agents_dir, "untrusted-agent",
                    { "name" => "untrusted-agent", "description" => "u" }, "body")

        allow(Rubino::Workspace).to receive(:primary_root).and_return(project)
        Dir.chdir(project) do
          loader = described_class.new(registry: registry,
                                       include_project_local: false)
          loader.load!

          expect(registry.find("untrusted-agent")).to be_nil
        end
      end
    end

    it "trust-gates .claude/agents like .rubino/agents" do
      Dir.mktmpdir do |tmp|
        project = File.realpath(tmp)
        claude_dir = File.join(project, ".claude", "agents")
        FileUtils.mkdir_p(claude_dir)
        write_agent(claude_dir, "claude-proj",
                    { "name" => "claude-proj", "description" => "c" }, "body")

        allow(Rubino::Workspace).to receive(:primary_root).and_return(project)
        Dir.chdir(project) do
          # Trusted: loads
          t_registry = Rubino::Agent::AgentRegistry.new(load_file_agents: false)
          t_loader = described_class.new(registry: t_registry,
                                         include_project_local: true)
          t_loader.load!
          expect(t_registry.find("claude-proj")).not_to be_nil

          # Untrusted: skipped
          u_registry = Rubino::Agent::AgentRegistry.new(load_file_agents: false)
          u_loader = described_class.new(registry: u_registry,
                                         include_project_local: false)
          u_loader.load!
          expect(u_registry.find("claude-proj")).to be_nil
        end
      end
    end
  end

  # ------------------------------------------------------------------
  # Malformed files
  # ------------------------------------------------------------------

  describe "error handling" do
    it "skips files without YAML frontmatter" do
      Dir.mktmpdir do |tmp|
        dir = File.join(tmp, "agents")
        FileUtils.mkdir_p(dir)
        File.write(File.join(dir, "nofm.md"), "just some markdown, no frontmatter")

        loader = described_class.new(registry: registry, include_project_local: true)
        allow(loader).to receive(:scan_dirs).and_return([dir])

        expect { loader.load! }.not_to raise_error
        expect(registry.find("nofm")).to be_nil
      end
    end

    it "skips files without a name in frontmatter" do
      Dir.mktmpdir do |tmp|
        dir = File.join(tmp, "agents")
        FileUtils.mkdir_p(dir)
        File.write(File.join(dir, "noname.md"),
                   "---\ndescription: no name here\n---\nbody")

        loader = described_class.new(registry: registry, include_project_local: true)
        allow(loader).to receive(:scan_dirs).and_return([dir])

        expect { loader.load! }.not_to raise_error
      end
    end

    it "warns on malformed YAML frontmatter" do
      Dir.mktmpdir do |tmp|
        dir = File.join(tmp, "agents")
        FileUtils.mkdir_p(dir)
        File.write(File.join(dir, "bad-yaml.md"),
                   "---\nname: bad\n  bad: indentation: broke\n---\nbody")

        loader = described_class.new(registry: registry, include_project_local: true)
        allow(loader).to receive(:scan_dirs).and_return([dir])

        log_io = StringIO.new
        Rubino.logger = Rubino::Logger.new(io: log_io)
        loader.load!
        expect(log_io.string).to include("agent.md.malformed_frontmatter")
        expect(registry.find("bad")).to be_nil
      end
    end

    it "skips files with non-Hash frontmatter" do
      Dir.mktmpdir do |tmp|
        dir = File.join(tmp, "agents")
        FileUtils.mkdir_p(dir)
        File.write(File.join(dir, "nonhash.md"),
                   "---\n- just a list\n- not a hash\n---\nbody")

        loader = described_class.new(registry: registry, include_project_local: true)
        allow(loader).to receive(:scan_dirs).and_return([dir])

        log_io = StringIO.new
        Rubino.logger = Rubino::Logger.new(io: log_io)
        loader.load!
        expect(log_io.string).to include("agent.md.nonhash_frontmatter")
      end
    end
  end
end
