# frozen_string_literal: true

RSpec.describe Rubino::Interaction::ClipboardImage do
  describe ".save_to_tempfile (macOS / pngpaste)" do
    before { stub_const("RbConfig::CONFIG", RbConfig::CONFIG.merge("host_os" => "darwin23")) }

    it "shells out to pngpaste and returns the temp path on success" do
      allow(described_class).to receive(:which).with("pngpaste").and_return(true)
      # Simulate pngpaste writing a PNG to the dest path it's handed.
      allow(Open3).to receive(:capture2e) do |_tool, dest|
        File.binwrite(dest, "PNGDATA")
        ["", instance_double(Process::Status, success?: true)]
      end

      path = described_class.save_to_tempfile

      expect(path).to end_with(".png")
      expect(File.read(path)).to eq("PNGDATA")
    ensure
      File.delete(path) if path && File.exist?(path)
    end

    it "returns nil when pngpaste is not installed" do
      allow(described_class).to receive(:which).and_return(false)

      expect(described_class.save_to_tempfile).to be_nil
    end

    it "returns nil when pngpaste exits without writing a file" do
      allow(described_class).to receive(:which).with("pngpaste").and_return(true)
      allow(Open3).to receive(:capture2e)
        .and_return(["no image", instance_double(Process::Status, success?: false)])

      expect(described_class.save_to_tempfile).to be_nil
    end

    it "gives a macOS-specific unavailable reason" do
      expect(described_class.unavailable_reason).to include("pngpaste")
    end
  end

  describe ".save_to_tempfile (Linux / stdout tools)" do
    before { stub_const("RbConfig::CONFIG", RbConfig::CONFIG.merge("host_os" => "linux-gnu")) }

    it "writes wl-paste stdout bytes to the temp file" do
      allow(described_class).to receive(:which).with("wl-paste").and_return(true)
      allow(Open3).to receive(:capture2)
        .and_return(["PNGBYTES", instance_double(Process::Status, success?: true)])

      path = described_class.save_to_tempfile

      expect(File.read(path)).to eq("PNGBYTES")
    ensure
      File.delete(path) if path && File.exist?(path)
    end
  end
end
