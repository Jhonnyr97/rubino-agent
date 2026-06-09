# frozen_string_literal: true

require "spec_helper"
require "base64"
require "stringio"

RSpec.describe Rubino::Boot::EncryptionKey do
  around do |ex|
    previous = ENV.fetch("RUBINO_ENCRYPTION_KEY", nil)
    ex.run
    ENV["RUBINO_ENCRYPTION_KEY"] = previous
  end

  let(:stderr) { StringIO.new }

  context "when the env var is missing" do
    before { ENV.delete("RUBINO_ENCRYPTION_KEY") }

    it "writes a clear message and exits 1" do
      expect do
        described_class.validate!(stderr: stderr)
      end.to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }

      expect(stderr.string).to include("RUBINO_ENCRYPTION_KEY invalid")
      expect(stderr.string).to include("not set")
    end

    it "hints at how to generate a key" do
      expect do
        described_class.validate!(stderr: stderr)
      end.to raise_error(SystemExit)

      expect(stderr.string).to include("SecureRandom.random_bytes(32)")
    end
  end

  context "when the env var is empty" do
    before { ENV["RUBINO_ENCRYPTION_KEY"] = "" }

    it "exits 1" do
      expect do
        described_class.validate!(stderr: stderr)
      end.to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
    end
  end

  context "when the key decodes to the wrong length" do
    before { ENV["RUBINO_ENCRYPTION_KEY"] = Base64.strict_encode64("short") }

    it "exits 1 with a length-specific message" do
      expect do
        described_class.validate!(stderr: stderr)
      end.to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }

      expect(stderr.string).to include("32 bytes")
    end
  end

  context "when the key is not valid base64" do
    before { ENV["RUBINO_ENCRYPTION_KEY"] = "!!!not base64!!!" }

    it "exits 1 rather than letting a Base64 ArgumentError bubble" do
      expect do
        described_class.validate!(stderr: stderr)
      end.to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }

      expect(stderr.string).to include("RUBINO_ENCRYPTION_KEY invalid")
    end
  end

  context "when the key is valid" do
    before do
      ENV["RUBINO_ENCRYPTION_KEY"] = Base64.strict_encode64(SecureRandom.random_bytes(32))
    end

    it "returns nil without exiting or writing anything" do
      expect(described_class.validate!(stderr: stderr)).to be_nil
      expect(stderr.string).to eq("")
    end
  end
end
