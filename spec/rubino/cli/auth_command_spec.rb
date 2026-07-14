# frozen_string_literal: true

require "spec_helper"
require "thor"
require "base64"
require "faraday"

RSpec.describe Rubino::CLI::AuthCommand do
  let(:command) { described_class.new }

  before do
    with_test_db
    Rubino::OAuth::Registry.reset!
    @prev_key = ENV.fetch("RUBINO_ENCRYPTION_KEY", nil)
    ENV["RUBINO_ENCRYPTION_KEY"] = Base64.strict_encode64("0" * 32)
  end

  after do
    Rubino::OAuth::Registry.reset!
    ENV["RUBINO_ENCRYPTION_KEY"] = @prev_key
  end

  # ------------------------------------------------------------------
  # Helpers
  # ------------------------------------------------------------------
  def register_dummy_provider(browser_flow: true)
    klass = Class.new(Rubino::OAuth::Provider) do
      define_singleton_method(:id)            { :dummy }
      define_singleton_method(:display_name)  { "Dummy" }
      define_singleton_method(:site)          { "https://dummy.test" }
      define_singleton_method(:authorize_path) { "/oauth/authorize" }
      define_singleton_method(:token_path)     { "/oauth/token" }
      define_singleton_method(:default_scopes) { %w[read] }
      define_singleton_method(:browser_flow?)  { browser_flow }

      define_method(:fetch_account_info) do |_token|
        { account_id: "user-1", account_email: "u@test", metadata: {} }
      end

      define_method(:revoke) { |_token| true }
    end

    instance = klass.new(client_id: "cid", client_secret: "csec")
    Rubino::OAuth::Registry.register(:dummy, instance)
    [klass, instance]
  end

  def register_dummy_device_provider
    klass = Class.new(Rubino::OAuth::Provider) do
      include Rubino::OAuth::DeviceCodeFlow

      define_singleton_method(:id)            { :dummy_device }
      define_singleton_method(:display_name)  { "DummyDevice" }
      define_singleton_method(:site)          { "https://dd.test" }
      define_singleton_method(:authorize_path) { "/auth" }
      define_singleton_method(:token_path)     { "/token" }
      define_singleton_method(:default_scopes) { %w[read] }
      define_singleton_method(:device_authorization_endpoint) { "https://dd.test/device/code" }

      define_method(:fetch_account_info) do |_token|
        { account_id: "user-dd", account_email: "dd@test", metadata: {} }
      end
    end

    instance = klass.new(client_id: "cid", client_secret: "csec")
    Rubino::OAuth::Registry.register(:dummy_device, instance)
    [klass, instance]
  end

  def stub_ui
    allow(Rubino).to receive(:ui).and_return(
      double("ui", info: nil, warn: nil, error: nil, debug: nil,
             table: nil, success: nil, say: nil)
    )
  end

  # ------------------------------------------------------------------
  # status
  # ------------------------------------------------------------------
  describe "#status" do
    before { stub_ui }

    it "prints a message when no connections exist" do
      expect { command.status }.not_to raise_error
      expect(Rubino.ui).to have_received(:info).with(/No OAuth connections/)
    end

    it "lists connections when they exist" do
      repo = Rubino::OAuth::ConnectionRepository.new
      repo.upsert(provider: :github, account_id: "u1", access_token: "tok",
                  account_email: "u1@test", scopes: %w[repo])

      command.status
      expect(Rubino.ui).to have_received(:table)
    end

    it "prints a friendly message (no backtrace) when RUBINO_ENCRYPTION_KEY is unset" do
      ENV.delete("RUBINO_ENCRYPTION_KEY")
      expect { command.status }.not_to raise_error
      expect(Rubino.ui).to have_received(:error).with(/RUBINO_ENCRYPTION_KEY not set/)
    end
  end

  # ------------------------------------------------------------------
  # logout
  # ------------------------------------------------------------------
  describe "#logout" do
    before { stub_ui }

    it "prints a message when no connections exist for the provider" do
      register_dummy_provider

      command.logout("dummy")
      expect(Rubino.ui).to have_received(:info).with(/No connections found/)
    end

    it "revokes and removes connections" do
      klass, provider = register_dummy_provider
      allow(provider).to receive(:revoke).and_return(true)

      repo = Rubino::OAuth::ConnectionRepository.new
      conn = repo.upsert(provider: :dummy, account_id: "u1", access_token: "tok",
                         account_email: "u1@test", scopes: %w[read])

      command.logout("dummy")
      expect(provider).to have_received(:revoke)
      expect(repo.find(conn[:id])).to be_nil
    end

    it "continues after revoke failure (best-effort)" do
      _, provider = register_dummy_provider
      allow(provider).to receive(:revoke).and_raise(StandardError, "boom")

      repo = Rubino::OAuth::ConnectionRepository.new
      conn = repo.upsert(provider: :dummy, account_id: "u1", access_token: "tok")

      command.logout("dummy")
      expect(Rubino.ui).to have_received(:warn).with(/boom/)
      expect(repo.find(conn[:id])).to be_nil
    end

    it "prints a friendly message (no backtrace) when RUBINO_ENCRYPTION_KEY is unset" do
      register_dummy_provider
      ENV.delete("RUBINO_ENCRYPTION_KEY")
      expect { command.logout("dummy") }.not_to raise_error
      expect(Rubino.ui).to have_received(:error).with(/RUBINO_ENCRYPTION_KEY not set/)
    end

    it "raises for unknown provider" do
      expect { command.logout("no-such") }.to raise_error(Thor::Error, /unknown provider/)
    end
  end

  # ------------------------------------------------------------------
  # login — provider resolution
  # ------------------------------------------------------------------
  describe "#login" do
    before { stub_ui }

    it "raises for unknown provider" do
      expect { command.login("no-such") }.to raise_error(Thor::Error, /unknown provider/)
    end

    it "loads providers from config if registry is empty" do
      register_dummy_provider
      cmd = described_class.new
      allow(cmd).to receive(:browser_login).and_return(nil)

      expect { cmd.login("dummy") }.not_to raise_error
    end

    # ------------------------------------------------------------------
    # Flow selection: browser vs device code vs manual paste
    # ------------------------------------------------------------------
    describe "flow selection" do
      it "uses browser flow for a standard PKCE provider" do
        register_dummy_provider(browser_flow: true)
        cmd = described_class.new

        allow(cmd).to receive(:browser_login)
        allow(cmd).to receive(:device_code_login)
        allow(cmd).to receive(:manual_paste_login)

        cmd.login("dummy")
        expect(cmd).to have_received(:browser_login).once
        expect(cmd).not_to have_received(:device_code_login)
        expect(cmd).not_to have_received(:manual_paste_login)
      end

      it "uses device code flow when --device flag is set" do
        _, provider = register_dummy_device_provider
        allow(provider.class).to receive(:browser_flow?).and_return(true)

        cmd = described_class.new([], { device: true })
        allow(cmd).to receive(:browser_login)
        allow(cmd).to receive(:device_code_login)
        allow(cmd).to receive(:manual_paste_login)

        cmd.login("dummy_device")
        expect(cmd).to have_received(:device_code_login).once
        expect(cmd).not_to have_received(:browser_login)
        expect(cmd).not_to have_received(:manual_paste_login)
      end

      it "uses device code flow for a device-code-only provider (MiniMax)" do
        _, provider = register_dummy_device_provider
        allow(provider.class).to receive(:browser_flow?).and_return(false)

        cmd = described_class.new
        allow(cmd).to receive(:browser_login)
        allow(cmd).to receive(:device_code_login)
        allow(cmd).to receive(:manual_paste_login)

        cmd.login("dummy_device")
        expect(cmd).to have_received(:device_code_login).once
        expect(cmd).not_to have_received(:browser_login)
        expect(cmd).not_to have_received(:manual_paste_login)
      end

      it "uses manual-paste flow when --manual-paste flag is set" do
        register_dummy_provider

        cmd = described_class.new([], { manual_paste: true })
        allow(cmd).to receive(:browser_login)
        allow(cmd).to receive(:device_code_login)
        allow(cmd).to receive(:manual_paste_login)

        cmd.login("dummy")
        expect(cmd).to have_received(:manual_paste_login).once
        expect(cmd).not_to have_received(:browser_login)
        expect(cmd).not_to have_received(:device_code_login)
      end
    end

    # ------------------------------------------------------------------
    # Remote session detection
    # ------------------------------------------------------------------
    describe "remote_session?" do
      it "returns true when SSH_CLIENT is set" do
        allow(ENV).to receive(:[]).and_call_original
        allow(ENV).to receive(:[]).with("SSH_CLIENT").and_return("1.2.3.4 1234 22")
        allow(ENV).to receive(:[]).with("SSH_TTY").and_return(nil)
        expect(command.send(:remote_session?)).to be true
      end

      it "returns true when SSH_TTY is set" do
        allow(ENV).to receive(:[]).and_call_original
        allow(ENV).to receive(:[]).with("SSH_CLIENT").and_return(nil)
        allow(ENV).to receive(:[]).with("SSH_TTY").and_return("/dev/pts/0")
        expect(command.send(:remote_session?)).to be true
      end

      it "returns true for CODESPACES" do
        allow(ENV).to receive(:[]).and_call_original
        allow(ENV).to receive(:[]).with("CODESPACES").and_return("true")
        expect(command.send(:remote_session?)).to be true
      end

      it "returns false on a local machine" do
        allow(ENV).to receive(:[]).and_call_original
        allow(ENV).to receive(:[]).with("SSH_CLIENT").and_return(nil)
        allow(ENV).to receive(:[]).with("SSH_TTY").and_return(nil)
        allow(ENV).to receive(:[]).with("CODESPACES").and_return(nil)
        allow(ENV).to receive(:[]).with("GITPOD_WORKSPACE_ID").and_return(nil)
        expect(command.send(:remote_session?)).to be false
      end
    end

    # ------------------------------------------------------------------
    # parse_pasted_callback — unit
    # ------------------------------------------------------------------
    describe "parse_pasted_callback" do
      it "extracts code and state from a full URL" do
        result = command.send(:parse_pasted_callback,
          "http://127.0.0.1:54321/oauth/callback?code=abc123&state=xyz789")
        expect(result).to eq({ "code" => "abc123", "state" => "xyz789" })
      end

      it "extracts code and state from a query-only fragment" do
        result = command.send(:parse_pasted_callback, "?code=abc&state=xyz")
        expect(result).to eq({ "code" => "abc", "state" => "xyz" })
      end

      it "extracts code and state from a bare query string" do
        result = command.send(:parse_pasted_callback, "code=def&state=uvw")
        expect(result).to eq({ "code" => "def", "state" => "uvw" })
      end

      it "treats bare string as a code" do
        result = command.send(:parse_pasted_callback, "bare_code_123")
        expect(result).to eq({ "code" => "bare_code_123" })
      end

      it "returns empty hash for blank input" do
        expect(command.send(:parse_pasted_callback, "")).to eq({})
        expect(command.send(:parse_pasted_callback, nil)).to eq({})
      end

      it "handles URL-encoded parameters" do
        result = command.send(:parse_pasted_callback,
          "http://localhost/cb?code=abc%20123&state=xyz%3D%3D")
        expect(result["code"]).to eq("abc 123")
        expect(result["state"]).to eq("xyz==")
      end
    end
  end
end
