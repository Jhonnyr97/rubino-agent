# frozen_string_literal: true

require "spec_helper"
require "stringio"

RSpec.describe Rubino::Boot::ConfigGuard do
  let(:home_path) { File.join(TEST_HOME, "config_guard_#{SecureRandom.hex(4)}") }
  let(:loader) { Rubino::Config::Loader.new(home_path: home_path) }
  let(:config_path) { File.join(home_path, "config.yml") }
  let(:stderr) { StringIO.new }

  before { FileUtils.mkdir_p(home_path) }
  after  { FileUtils.rm_rf(home_path) }

  # CFG-1: a malformed config.yml used to crash the entrypoint
  # (exe/rubino:16) with a raw Ruby+Psych double backtrace, killing EVERY
  # command before Thor dispatch and bypassing doctor's graceful handler.
  context "with a malformed config.yml" do
    before do
      File.write(config_path, "model:\n  : : :\n  bad yaml [\n")
    end

    it "exits non-zero instead of raising a backtrace" do
      expect do
        described_class.load!(loader: loader, stderr: stderr)
      end.to raise_error(SystemExit) { |e| expect(e.status).not_to eq(0) }
    end

    it "writes a clean, actionable diagnostic with the config path and no backtrace" do
      expect do
        described_class.load!(loader: loader, stderr: stderr)
      end.to raise_error(SystemExit)

      out = stderr.string
      expect(out).to include("config error")
      expect(out).to include(config_path)
      expect(out).to include("rubino setup")
      # No Ruby/Psych stack-trace frames leaked.
      expect(out).not_to match(/psych/i)
      expect(out).not_to match(/\.rb:\d+:in/)
    end
  end

  context "with a single-colon scalar config" do
    before { File.write(config_path, ":\n") }

    it "aborts cleanly rather than crashing" do
      expect do
        described_class.load!(loader: loader, stderr: stderr)
      end.to raise_error(SystemExit) { |e| expect(e.status).not_to eq(0) }
      expect(stderr.string).to include("config error")
    end
  end

  context "with a valid config" do
    before { loader.create_default_config! }

    it "loads without exiting and returns nil" do
      result = nil
      expect do
        result = described_class.load!(loader: loader, stderr: stderr)
      end.not_to raise_error
      expect(result).to be_nil
      expect(stderr.string).to be_empty
    end
  end

  context "with no config file" do
    it "loads defaults without exiting" do
      expect do
        described_class.load!(loader: loader, stderr: stderr)
      end.not_to raise_error
      expect(stderr.string).to be_empty
    end
  end
end
