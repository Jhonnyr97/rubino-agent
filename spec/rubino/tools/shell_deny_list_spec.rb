# frozen_string_literal: true

# Commands on the hardline blocklist must be refused at the tool boundary,
# BEFORE the approval policy is even consulted — `--yolo` bypasses approval by
# design and would otherwise license a single confused prompt to wipe the host.
# ShellTool delegates this check to Security::HardlineGuard (single source of
# truth), so this spec exercises the delegation, not a divergent inline list.
RSpec.describe Rubino::Tools::ShellTool do
  subject(:tool) { described_class.new }

  describe "hardline destructive deny-list (delegated to HardlineGuard)" do
    def expect_blocked(command, label_match)
      result = tool.call("command" => command)
      msg = result.is_a?(Hash) ? result[:output].to_s : result.to_s
      expect(msg).to start_with("Error: refusing to run")
      expect(msg).to match(label_match)
      expect(msg).to include("hardcoded as destructive")
    end

    def expect_allowed(command)
      # We don't actually want to execute these in the test process — assert
      # only that the deny-list does NOT match. The deny-list runs before any
      # spawn so we can check it via the same method that ShellTool#call uses.
      expect(tool.send(:destructive_pattern_match, command)).to be_nil
    end

    it "blocks rm -rf /" do
      expect_blocked("rm -rf /", /root filesystem/)
    end

    it "blocks rm -fr / (flag order swap)" do
      expect_blocked("rm -fr /", /root filesystem/)
    end

    it "blocks rm -rf /*" do
      expect_blocked("rm -rf /*", /root filesystem/)
    end

    it "blocks rm -rf /etc (system directory)" do
      expect_blocked("rm -rf /etc", /system directory/)
    end

    it "blocks dd of=/dev/sda" do
      expect_blocked("dd if=image.iso of=/dev/sda bs=4M", /raw block device/)
    end

    it "blocks dd of=/dev/nvme0n1" do
      expect_blocked("dd if=/zero of=/dev/nvme0n1", /raw block device/)
    end

    it "blocks mkfs.ext4 /dev/sdb" do
      expect_blocked("mkfs.ext4 /dev/sdb", /format filesystem/)
    end

    it "blocks classic fork bomb" do
      expect_blocked(":(){:|:&};:", /fork bomb/)
    end

    it "blocks fork bomb with extra whitespace" do
      expect_blocked(": ( ) { : | : & } ; :", /fork bomb/)
    end

    it "blocks echo > /dev/sda" do
      expect_blocked("echo wipe > /dev/sda", /raw block device/)
    end

    it "blocks chmod -R 000 /" do
      expect_blocked("chmod -R 000 /", /chmod\/chown of root filesystem/)
    end

    it "blocks shutdown now" do
      expect_blocked("shutdown now", /shutdown\/reboot/)
    end

    it "allows rm -rf node_modules (no root target)" do
      expect_allowed("rm -rf node_modules")
    end

    it "allows rm -rf /tmp/some-build" do
      expect_allowed("rm -rf /tmp/some-build")
    end

    it "allows dd of=image.iso (regular file)" do
      expect_allowed("dd if=/dev/zero of=image.iso bs=1M count=10")
    end

    it "allows chmod -R 755 ./bin" do
      expect_allowed("chmod -R 755 ./bin")
    end

    it "does not false-positive on echo reboot" do
      expect_allowed("echo reboot")
    end

    it "does not false-positive on grep shutdown app.log" do
      expect_allowed("grep shutdown app.log")
    end
  end
end
