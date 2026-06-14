# frozen_string_literal: true

RSpec.describe Rubino::Security::HardlineGuard do
  describe ".detect" do
    # Each catastrophic, unrecoverable command must be flagged. Descriptions
    # are matched loosely so wording tweaks don't make the spec brittle.
    {
      "rm -rf /" => /root filesystem/,
      "rm -fr /" => /root filesystem/,
      "rm -rf /*" => /root filesystem/,
      "rm   -rf   /" => /root filesystem/,
      "rm -rf /etc" => /system directory/,
      "rm -rf /home/*" => /system directory/,
      "rm -rf ~" => /home directory/,
      "rm -rf $HOME" => /home directory/,
      "mkfs.ext4 /dev/sdb" => /format filesystem/,
      "mkfs -t ext4 /dev/loop0" => /format filesystem/,
      "dd if=x of=/dev/sda bs=4M" => /dd to raw block device/,
      "echo x > /dev/nvme0n1" => /redirect to raw block device/,
      ":(){:|:&};:" => /fork bomb/,
      ": ( ) { : | : & } ; :" => /fork bomb/,
      "kill -9 -1" => /kill all processes/,
      "shutdown now" => %r{shutdown/reboot},
      "sudo reboot" => %r{shutdown/reboot},
      "systemctl poweroff" => %r{systemctl poweroff/reboot},
      "init 0" => %r{init 0/6},
      "telinit 6" => %r{telinit 0/6},
      "chmod -R 000 /" => %r{chmod/chown of root filesystem},
      "chown -R nobody /" => %r{chmod/chown of root filesystem},
      "echo hi && rm -rf /" => /root filesystem/,
      "halt" => %r{shutdown/reboot},
      # #325: canonicalization bypasses that the pre-fix normalize() missed.
      "rm -rf '/'" => /root filesystem/,            # single-quoted root
      "rm -rf \"/\"" => /root filesystem/,          # double-quoted root
      "rm -rf //" => /root filesystem/,             # double-slash root
      "rm -rf /." => /root filesystem/,             # /. equivalent to /
      "rm -rf /./" => /root filesystem/,            # /./ equivalent to /
      "rm -rf /usr/" => /system directory/,         # trailing slash
      "rm -rf '/usr'" => /system directory/,        # quoted system dir
      "rm -rf ${HOME}" => /home directory/,         # brace-expanded $HOME
      "rm -rf \"$HOME\"" => /home directory/,       # quoted $HOME
      "rm -rf ${home}" => /home directory/,         # brace lowercase home
      # #348: line-continuation, ${IFS} word-split, ${HOME:-/} param-default.
      "rm -rf \\\n/" => /root filesystem/,          # backslash-newline continuation
      "rm -rf \\\n  /" => /root filesystem/,        # continuation + leading indent
      "rm \\\n  -rf \\\n  /" => /root filesystem/,  # multiple continuations
      "rm${IFS}-rf${IFS}/" => /root filesystem/,    # ${IFS} word-splitting
      "rm${IFS}-rf${IFS}/etc" => /system directory/, # ${IFS} -> system dir
      "rm -rf ${HOME:-/}" => /root filesystem/,     # ${HOME:-/} defaults to /
      "rm -rf ${HOME:=/}" => /root filesystem/      # ${HOME:=/} defaults to /
    }.each do |command, description_match|
      it "blocks #{command.inspect}" do
        blocked, description = described_class.detect(command)
        expect(blocked).to be(true)
        expect(description).to match(description_match)
      end
    end

    # Legitimate commands that superficially resemble hardline ones — false
    # positives here would block real work, so they must pass clean.
    [
      "rm -rf node_modules",
      "rm -rf /tmp/some-build",
      "rm -rf ./dist",
      "ls /etc",
      "cat /etc/hosts",
      "dd if=/dev/zero of=image.iso bs=1M count=10",
      "echo reboot",
      "grep shutdown app.log",
      "echo 'shutdown the server later'",
      "git status",
      "git reset --hard",
      "chmod -R 755 ./bin",
      "kill -9 1234",
      "systemctl status nginx",
      # #325: canonicalization must NOT introduce false positives on legit paths
      # that merely contain a trailing slash, a dot-relative, or a bare slash.
      "rm -rf /tmp/build/",
      "rm -rf ./node_modules",
      "echo /",
      # #348: the new continuation/word-split handling must NOT add false
      # positives on legit multi-line / IFS-adjacent commands.
      "rm -rf \\\n/tmp/build",       # continuation to a SAFE path
      "echo hello \\\nworld",        # continuation in a harmless command
      "rm${IFS}-rf${IFS}/tmp/build"  # ${IFS} to a SAFE path
    ].each do |command|
      it "allows #{command.inspect}" do
        blocked, = described_class.detect(command)
        expect(blocked).to be(false)
      end
    end

    it "tolerates a nil command" do
      expect(described_class.detect(nil)).to eq([false, nil])
    end
  end

  describe "sudo -S stdin password-guessing guard" do
    it "blocks sudo -S when SUDO_PASSWORD is not configured" do
      stub_const("ENV", ENV.to_h.tap { |h| h.delete("SUDO_PASSWORD") })
      blocked, description = described_class.detect("sudo -S whoami")
      expect(blocked).to be(true)
      expect(description).to include("sudo -S")
    end

    it "does NOT fire when SUDO_PASSWORD is configured (legit internal path)" do
      stub_const("ENV", ENV.to_h.merge("SUDO_PASSWORD" => "secret"))
      blocked, = described_class.detect("sudo -S whoami")
      expect(blocked).to be(false)
    end
  end

  describe ".block_reason" do
    it "returns the description string for a hardline command" do
      expect(described_class.block_reason("rm -rf /")).to include("root filesystem")
    end

    it "returns nil for a safe command" do
      expect(described_class.block_reason("ls -la")).to be_nil
    end
  end
end
