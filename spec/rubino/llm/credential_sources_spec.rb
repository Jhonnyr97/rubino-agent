# frozen_string_literal: true

require "spec_helper"
require "json"
require "tmpdir"
require "fileutils"
require "open3"

RSpec.describe Rubino::LLM::CredentialSources do
  describe ".resolve" do
    it "returns nil for an unknown/non-oauth provider" do
      expect(described_class.resolve("openai")).to be_nil
    end

    it "returns nil for anthropic when no credential store is available" do
      # Stub the Keychain read (macOS) to return failure so no token is found.
      allow(Open3).to receive(:capture2).and_return(["", double(success?: false)])
      # Also ensure no file exists.
      allow(File).to receive(:readable?).and_return(false)
      expect(described_class.resolve("anthropic")).to be_nil
    end
  end

  describe ".expired?" do
    it "returns false when no expires_at is present" do
      expect(described_class.expired?({ api_key: "x" })).to be false
    end

    it "returns false when expires_at is zero" do
      expect(described_class.expired?({ api_key: "x", expires_at: 0 })).to be false
    end

    it "returns true when expires_at is in the past (epoch ms)" do
      past_ms = ((Time.now.utc.to_f - 3600) * 1000).to_i
      creds = { api_key: "x", expires_at: past_ms }
      expect(described_class.expired?(creds, skew_seconds: 0)).to be true
    end

    it "returns true when within the skew window (epoch ms)" do
      near_ms = ((Time.now.utc.to_f + 60) * 1000).to_i
      creds = { api_key: "x", expires_at: near_ms }
      expect(described_class.expired?(creds, skew_seconds: 120)).to be true
    end

    it "returns false when outside the skew window (epoch ms)" do
      future_ms = ((Time.now.utc.to_f + 600) * 1000).to_i
      creds = { api_key: "x", expires_at: future_ms }
      expect(described_class.expired?(creds, skew_seconds: 120)).to be false
    end

    it "treats expires_at as Integer (not ISO8601 string)" do
      # The old code did Time.parse on an Integer, which raised ArgumentError
      # and was treated as always-expired.  Epoch ms Integers must work.
      future_ms = ((Time.now.utc.to_f + 600) * 1000).to_i
      creds = { api_key: "x", expires_at: future_ms }
      expect(described_class.expired?(creds, skew_seconds: 120)).to be false
    end
  end

  # ------------------------------------------------------------------
  # AnthropicOAuth
  # ------------------------------------------------------------------
  describe Rubino::LLM::CredentialSources::AnthropicOAuth do
    let(:source) { described_class.new }

    describe "#priority" do
      it "is 10 (outranks static env vars)" do
        expect(source.priority).to eq(10)
      end
    end

    describe "#resolve" do
      it "returns nil for non-anthropic providers" do
        expect(source.resolve("openai")).to be_nil
        expect(source.resolve("google")).to be_nil
      end

      it "returns nil when neither cred file nor Keychain has tokens" do
        # Stub Keychain read to failure on macOS
        allow(Open3).to receive(:capture2).and_return(["", double(success?: false)])
        # Force non-macOS so we also try the file path (which doesn't exist)
        stub_const("RUBY_PLATFORM", "x86_64-linux")
        s = described_class.new(claude_cred_path: "/nonexistent/path.json")
        expect(s.resolve("anthropic")).to be_nil
      end

      # ------------------------------------------------------------------
      # File-based (Linux / non-macOS)
      # ------------------------------------------------------------------
      context "with Claude Code credential file (Linux / non-macOS)" do
        let(:tmp_dir) { Dir.mktmpdir("rubino-oauth-test") }
        let(:cred_file) { File.join(tmp_dir, ".claude", ".credentials.json") }
        let(:source) { described_class.new(claude_cred_path: cred_file) }

        before do
          FileUtils.mkdir_p(File.dirname(cred_file))
          # Force non-macOS path
          stub_const("RUBY_PLATFORM", "x86_64-linux")
        end

        after do
          FileUtils.rm_rf(tmp_dir)
        end

        it "resolves from claudeAiOauth container with camelCase keys" do
          expires_ms = ((Time.now.utc.to_f + 3600) * 1000).to_i
          File.write(cred_file, JSON.generate(
            "claudeAiOauth" => {
              "accessToken"           => "sk-ant...oken",
              "refreshToken"          => "sk-ant...resh",
              "expiresAt"             => expires_ms,
              "refreshTokenExpiresAt" => expires_ms + 86_400_000,
              "scopes"                => ["user:inference", "user:profile"],
              "subscriptionType"      => "max",
              "rateLimitTier"         => "default_claude_max_20x"
            }
          ))

          result = source.resolve("anthropic")
          expect(result).to be_a(Hash)
          expect(result[:api_key]).to eq("sk-ant...oken")
          expect(result[:expires_at]).to eq(expires_ms)
          expect(result[:refresh_token]).to eq("sk-ant...resh")
          expect(result[:source]).to eq("anthropic_oauth")
          expect(result[:scopes]).to include("user:inference")
        end

        it "resolves from flat Anthropic-native structure (camelCase, no wrapper)" do
          expires_ms = ((Time.now.utc.to_f + 3600) * 1000).to_i
          File.write(cred_file, JSON.generate(
            "accessToken"  => "sk-ant...oken",
            "refreshToken" => "sk-ant...resh",
            "expiresAt"    => expires_ms,
            "scopes"       => ["user:inference"]
          ))

          result = source.resolve("anthropic")
          expect(result).to be_a(Hash)
          expect(result[:api_key]).to eq("sk-ant...oken")
        end

        it "returns nil when accessToken is missing" do
          File.write(cred_file, JSON.generate("claudeAiOauth" => {}))
          expect(source.resolve("anthropic")).to be_nil
        end

        it "returns nil when file is unreadable / missing" do
          source = described_class.new(claude_cred_path: "/nonexistent/path.json")
          expect(source.resolve("anthropic")).to be_nil
        end
      end

      # ------------------------------------------------------------------
      # macOS Keychain
      # ------------------------------------------------------------------
      context "on macOS via Keychain" do
        before do
          stub_const("RUBY_PLATFORM", "arm64-darwin23")
        end

        it "reads from security find-generic-password and resolves the token" do
          expires_ms = ((Time.now.utc.to_f + 3600) * 1000).to_i
          keychain_json = JSON.generate(
            "claudeAiOauth" => {
              "accessToken"           => "sk-ant...oken",
              "refreshToken"          => "sk-ant...resh",
              "expiresAt"             => expires_ms,
              "refreshTokenExpiresAt" => expires_ms + 86_400_000,
              "scopes"                => ["user:inference"],
              "subscriptionType"      => "max",
              "rateLimitTier"         => "default_claude_max_20x"
            }
          )

          allow(Open3).to receive(:capture2).with(
            "security", "find-generic-password",
            "-s", "Claude Code-credentials", "-w"
          ).and_return([keychain_json, double(success?: true)])

          result = source.resolve("anthropic")
          expect(result).to be_a(Hash)
          expect(result[:api_key]).to eq("sk-ant...oken")
          expect(result[:expires_at]).to eq(expires_ms)
          expect(result[:source]).to eq("anthropic_oauth")
          expect(result[:_source_kind]).to eq(:keychain)
        end

        it "returns nil when security command fails" do
          allow(Open3).to receive(:capture2).with(
            "security", "find-generic-password",
            "-s", "Claude Code-credentials", "-w"
          ).and_return(["", double(success?: false)])

          expect(source.resolve("anthropic")).to be_nil
        end

        it "returns nil when security output is empty" do
          allow(Open3).to receive(:capture2).with(
            "security", "find-generic-password",
            "-s", "Claude Code-credentials", "-w"
          ).and_return(["", double(success?: true)])

          expect(source.resolve("anthropic")).to be_nil
        end
      end
    end

    describe "#refresh" do
      let(:tmp_dir) { Dir.mktmpdir("rubino-refresh-test") }
      let(:cred_file_dir) { File.join(tmp_dir, ".claude") }
      let(:cred_file) { File.join(cred_file_dir, ".credentials.json") }
      let(:future_ms) { ((Time.now.utc.to_f + 3600) * 1000).to_i }
      let(:creds) do
        {
          api_key:        "sk-ant-oat-old",
          refresh_token:  "sk-ant-ort-old",
          source:         "anthropic_oauth",
          scopes:         ["user:inference"],
          expires_at:     future_ms,
          _source_kind:   :file,
          _file_path:     cred_file
        }
      end

      let(:refresh_response_body) do
        {
          "access_token"  => "sk-ant-oat-new",
          "refresh_token" => "sk-ant-ort-new",
          "expires_in"    => 3600
        }.to_json
      end

      before do
        FileUtils.mkdir_p(cred_file_dir)
        allow(Faraday).to receive(:post).and_return(
          double(success?: true, body: refresh_response_body, status: 200)
        )
      end

      after do
        FileUtils.rm_rf(tmp_dir)
      end

      it "posts form-urlencoded to console.anthropic.com with client_id" do
        source.refresh(creds)

        expect(Faraday).to have_received(:post).with(
          "https://console.anthropic.com/v1/oauth/token",
          include("grant_type=refresh_token"),
          "Content-Type" => "application/x-www-form-urlencoded"
        )
      end

      it "includes client_id in the form body" do
        source.refresh(creds)

        expect(Faraday).to have_received(:post).with(
          anything,
          include("client_id=9d1c250a-e61b-44d9-88ed-5944d1962f5e"),
          anything
        )
      end

      it "returns refreshed credentials with expires_at in epoch ms" do
        result = source.refresh(creds)

        expect(result).to be_a(Hash)
        expect(result[:api_key]).to eq("sk-ant-oat-new")
        expect(result[:refresh_token]).to eq("sk-ant-ort-new")
        expect(result[:source]).to eq("anthropic_oauth")
        expect(result[:expires_at]).to be > ((Time.now.utc.to_f + 3500) * 1000).to_i
      end

      it "returns nil when refresh_token is missing from input" do
        expect(source.refresh(api_key: "tok", source: "x")).to be_nil
      end

      it "returns nil when the HTTP call fails" do
        allow(Faraday).to receive(:post).and_return(
          double(success?: false, body: "{}", status: 401)
        )

        expect(source.refresh(creds)).to be_nil
      end

      it "falls back to old refresh_token when server omits it" do
        body = { "access_token" => "sk-ant-oat-new", "expires_in" => 3600 }.to_json
        allow(Faraday).to receive(:post).and_return(
          double(success?: true, body: body, status: 200)
        )

        result = source.refresh(creds)
        expect(result[:refresh_token]).to eq("sk-ant-ort-old")
      end

      it "tries the platform.claude.com fallback when console fails" do
        # First URL fails, second succeeds
        call_count = 0
        allow(Faraday).to receive(:post) do |url, *|
          call_count += 1
          if call_count == 1
            double(success?: false, body: "{}", status: 500)
          else
            double(success?: true, body: refresh_response_body, status: 200)
          end
        end

        result = source.refresh(creds)
        expect(result[:api_key]).to eq("sk-ant-oat-new")
        expect(Faraday).to have_received(:post).with(
          "https://console.anthropic.com/v1/oauth/token", anything, anything
        )
        expect(Faraday).to have_received(:post).with(
          "https://platform.claude.com/v1/oauth/token", anything, anything
        )
      end

      # ── write-back: file-only, hermes parity ──────────────────────────

      it "writes refreshed tokens to the FILE (never Keychain)" do
        source.refresh(creds)

        expect(File.exist?(cred_file)).to be true
        written = JSON.parse(File.read(cred_file))
        expect(written).to have_key("claudeAiOauth")
        oauth = written["claudeAiOauth"]
        expect(oauth["accessToken"]).to eq("sk-ant-oat-new")
        expect(oauth["refreshToken"]).to eq("sk-ant-ort-new")
        expect(oauth["expiresAt"]).to be_a(Integer)
        expect(oauth["scopes"]).to eq(["user:inference"])
      end

      it "writes with 0600 mode" do
        source.refresh(creds)

        mode = File.stat(cred_file).mode & 0o777
        expect(mode).to eq(0o600)
      end

      it "preserves top-level sibling keys in the credentials file" do
        # Pre-populate the file with a sibling key
        existing = { "claudeAiOauth" => { "accessToken" => "old" }, "someSibling" => "kept" }
        File.write(cred_file, JSON.generate(existing))

        source.refresh(creds)

        written = JSON.parse(File.read(cred_file))
        expect(written).to have_key("someSibling")
        expect(written["someSibling"]).to eq("kept")
        expect(written).to have_key("claudeAiOauth")
        expect(written["claudeAiOauth"]["accessToken"]).to eq("sk-ant-oat-new")
      end

      it "does NOT call security add-generic-password (no Keychain write)" do
        allow(Open3).to receive(:capture2)
        source.refresh(creds)

        expect(Open3).not_to have_received(:capture2).with(
          "security", "add-generic-password", anything, anything, anything, anything
        )
      end

      it "writes to the file even when token was read from Keychain (_source_kind :keychain)" do
        keychain_creds = creds.merge(_source_kind: :keychain)
        source.refresh(keychain_creds)

        expect(File.exist?(cred_file)).to be true
        written = JSON.parse(File.read(cred_file))
        expect(written["claudeAiOauth"]["accessToken"]).to eq("sk-ant-oat-new")
      end
    end
  end

  # ------------------------------------------------------------------
  # Chain behaviour: .resolve with multiple sources
  # ------------------------------------------------------------------
  describe ".resolve chain" do
    it "walks sources in priority order" do
      high = double("high_priority", priority: 5)
      low  = double("low_priority",  priority: 20)

      allow(high).to receive(:resolve).with("anthropic").and_return(nil)
      allow(low).to receive(:resolve).with("anthropic").and_return(
        api_key: "from-low", source: "low"
      )

      allow(described_class).to receive(:registry).and_return([low, high])

      result = described_class.resolve("anthropic")
      expect(result[:api_key]).to eq("from-low")
    end

    it "skips expired credentials (epoch ms)" do
      past_ms = ((Time.now.utc.to_f - 3600) * 1000).to_i
      expired = { api_key: "old", expires_at: past_ms, source: "x" }
      src = double("source", priority: 5)
      allow(src).to receive(:resolve).with("anthropic").and_return(expired)

      allow(described_class).to receive(:registry).and_return([src])

      expect(described_class.resolve("anthropic")).to be_nil
    end
  end
end
