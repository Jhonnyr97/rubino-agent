# frozen_string_literal: true

RSpec.describe Rubino::CLI::ServerCommand do
  # Regression for the bug where API runs received `tools: []`. ServerCommand
  # has to populate the tool registry the same way ChatCommand does — without
  # this, Lifecycle#load_tools returns [], no `tools` field is sent on the
  # wire, and the model can only roleplay tool calls in markdown. The CLI was
  # covered by chat_command_spec; the server path was not, which is how the
  # bug shipped in 0.1.0/0.1.1.
  describe "tool registration" do
    before do
      Rubino::Tools::Registry.reset!
      # Stub the parts of ServerCommand#execute that would otherwise try to
      # bind a TCP socket or touch external state. We only care about the
      # registry side effect of execute.
      allow(Rubino::Boot::EncryptionKey).to receive(:validate!)
      allow(Rubino::OAuth::Registry).to receive(:load_from_config!)
      scheduler = instance_double(Rubino::Jobs::Scheduler, load_all!: nil, resume_pending_webhooks!: nil)
      allow(Rubino::Jobs::Scheduler).to receive(:instance).and_return(scheduler)
      server = instance_double(Rubino::API::Server, start!: nil)
      allow(Rubino::API::Server).to receive(:new).and_return(server)
    end

    it "registers default tools before starting the server" do
      expect(Rubino::Tools::Registry.all.size).to eq(0)

      described_class.new({}).execute

      expect(Rubino::Tools::Registry.all.size).to be > 0
      expect(Rubino::Tools::Registry.find("shell")).not_to be_nil
      expect(Rubino::Tools::Registry.find("read")).not_to be_nil
      expect(Rubino::Tools::Registry.find("write")).not_to be_nil
    end

    it "does not re-register if the registry is already populated" do
      Rubino::Tools::Registry.register(Rubino::Tools::ShellTool.new)
      before_count = Rubino::Tools::Registry.all.size

      described_class.new({}).execute

      expect(Rubino::Tools::Registry.all.size).to eq(before_count)
    end
  end

  # The fake LLM provider is a dev-only seam — it replays canned scenarios
  # instead of calling a real model. Booting the API server with it on by
  # accident would silently serve fake answers to real clients, so the
  # opt-in env flag is the only way to get past the guard.
  describe "fake provider guard" do
    before do
      Rubino::Tools::Registry.reset!
      allow(Rubino::Boot::EncryptionKey).to receive(:validate!)
      allow(Rubino::OAuth::Registry).to receive(:load_from_config!)
      scheduler = instance_double(Rubino::Jobs::Scheduler, load_all!: nil, resume_pending_webhooks!: nil)
      allow(Rubino::Jobs::Scheduler).to receive(:instance).and_return(scheduler)
      server = instance_double(Rubino::API::Server, start!: nil)
      allow(Rubino::API::Server).to receive(:new).and_return(server)
      ENV.delete("RUBINO_ALLOW_FAKE")
    end

    after { ENV.delete("RUBINO_ALLOW_FAKE") }

    it "aborts when provider is fake without RUBINO_ALLOW_FAKE=1" do
      cfg = test_configuration("model" => { "provider" => "fake", "default" => "fake/happy-path",
                                            "temperature" => 0.3, "context_length" => nil })
      allow(Rubino).to receive(:configuration).and_return(cfg)

      expect { described_class.new({}).execute }.to raise_error(SystemExit) do |err|
        expect(err.status).to eq(1)
      end
      expect(Rubino::API::Server).not_to have_received(:new)
    end

    it "boots when provider is fake and RUBINO_ALLOW_FAKE=1" do
      cfg = test_configuration("model" => { "provider" => "fake", "default" => "fake/happy-path",
                                            "temperature" => 0.3, "context_length" => nil })
      allow(Rubino).to receive(:configuration).and_return(cfg)
      ENV["RUBINO_ALLOW_FAKE"] = "1"

      expect { described_class.new({}).execute }.not_to raise_error
      expect(Rubino::API::Server).to have_received(:new)
    end
  end

  # TLS for the app→app hop: when enabled, a self-signed cert is generated/reused
  # and handed to the server; when disabled (local dev / fake), no cert is
  # generated and the server is started plain-HTTP.
  describe "TLS wiring" do
    let(:server) { instance_double(Rubino::API::Server, start!: nil) }

    before do
      Rubino::Tools::Registry.reset!
      allow(Rubino::Boot::EncryptionKey).to receive(:validate!)
      allow(Rubino::OAuth::Registry).to receive(:load_from_config!)
      scheduler = instance_double(Rubino::Jobs::Scheduler, load_all!: nil, resume_pending_webhooks!: nil)
      allow(Rubino::Jobs::Scheduler).to receive(:instance).and_return(scheduler)
      allow(Rubino::API::Server).to receive(:new).and_return(server)
    end

    after { ENV.delete("RUBINO_TLS") }

    it "generates/reuses the cert and passes cert+key to the server when TLS is enabled" do
      ENV["RUBINO_TLS"] = "1"
      allow(Rubino::API::TLS).to receive(:ensure_cert!)
      allow(Rubino::API::TLS).to receive(:cert_path).and_return("/home/tls/cert.pem")
      allow(Rubino::API::TLS).to receive(:key_path).and_return("/home/tls/key.pem")

      described_class.new({}).execute

      expect(Rubino::API::TLS).to have_received(:ensure_cert!).with(host: "127.0.0.1")
      expect(Rubino::API::Server).to have_received(:new)
        .with(hash_including(tls_cert: "/home/tls/cert.pem", tls_key: "/home/tls/key.pem"))
    end

    it "leaves the server plain-HTTP when TLS is disabled (local dev)" do
      ENV.delete("RUBINO_TLS")
      allow(Rubino::API::TLS).to receive(:enabled?).and_return(false)
      allow(Rubino::API::TLS).to receive(:ensure_cert!)

      described_class.new({}).execute

      expect(Rubino::API::TLS).not_to have_received(:ensure_cert!)
      expect(Rubino::API::Server).to have_received(:new)
        .with(hash_including(tls_cert: nil, tls_key: nil))
    end
  end
end
