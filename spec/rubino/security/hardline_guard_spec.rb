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
      "rm -rf ${HOME:=/}" => /root filesystem/,     # ${HOME:=/} defaults to /
      # #379 (residual of #348): line-continuation INSIDE a token, arbitrary
      # varname default, and the ${IFS:0:1} substring word-split form.
      "rm -r\\\nf /" => /root filesystem/,          # continuation splitting -rf
      "rm -rf ${X:-/}" => /root filesystem/,        # arbitrary varname default
      "rm -rf ${FOO:=/}" => /root filesystem/,      # arbitrary varname := default
      "rm${IFS:0:1}-rf${IFS:0:1}/" => /root filesystem/, # ${IFS:0:1} substring split
      "rm${IFS:0:1}-rf${IFS:0:1}/etc" => /system directory/, # ${IFS:0:1} -> system dir
      # #325 indirection gap: command substitution / backticks / brace-and-subshell
      # groups wrap a catastrophic command so the rm patterns (anchored on a
      # trailing space/EOL) miss the inner target. canonicalize now UNWRAPS them.
      "$(rm -rf /)" => /root filesystem/,           # command substitution
      "`rm -rf /`" => /root filesystem/,            # backtick substitution
      "$(rm -rf ~)" => /home directory/,            # substitution -> home
      "{ rm -rf /; }" => /root filesystem/,         # brace group
      "( rm -rf / )" => /root filesystem/,          # subshell group
      "echo $(rm -rf /*)" => /root filesystem/,     # padded substitution
      "$(echo $(rm -rf /))" => /root filesystem/    # nested substitution
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
      "rm${IFS}-rf${IFS}/tmp/build", # ${IFS} to a SAFE path
      # #379: continuation INSIDE a token / ${IFS:0:1} / varname-default folding
      # must not false-positive on safe targets.
      "rm -r\\\nf /tmp/build", # token-split continuation, SAFE path
      "rm${IFS:0:1}-rf${IFS:0:1}/tmp/build", # ${IFS:0:1} to a SAFE path
      "echo ${EDITOR:-vim}", # varname-default folding, harmless
      # #325: unwrapping substitution must NOT over-block NON-destructive
      # command substitutions — these run harmless inner commands.
      "$(date)",                      # bare substitution, harmless
      "$(ls)",                        # bare substitution, harmless
      "echo $(pwd)",                  # padded substitution, harmless
      "name=$(git rev-parse HEAD)",   # assignment from substitution
      "files=$(ls /tmp)",             # substitution over a safe path
      "echo ${IFS}"                   # ${IFS} param-expansion, not a group
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

    # MED audit fix: the guard must catch the stdin-password forms (-S, --stdin)
    # and NOT the unrelated `-s` (start a $SHELL). The guard is case-SENSITIVE;
    # the previous regex relied on the lowercasing normalizer, which collapsed
    # `-S` and `-s` together and missed `--stdin` entirely.
    context "with SUDO_PASSWORD unset" do
      before { stub_const("ENV", ENV.to_h.tap { |h| h.delete("SUDO_PASSWORD") }) }

      it "blocks the GNU long form sudo --stdin" do
        blocked, description = described_class.detect("sudo --stdin whoami")
        expect(blocked).to be(true)
        expect(description).to include("sudo -S")
      end

      it "blocks -S combined in a short-flag cluster (sudo -kS)" do
        blocked, = described_class.detect("sudo -kS whoami")
        expect(blocked).to be(true)
      end

      it "blocks sudo -S even after a command separator" do
        blocked, = described_class.detect("echo hi && sudo -S whoami")
        expect(blocked).to be(true)
      end

      it "does NOT flag sudo -s (start a shell, not the stdin-password flag)" do
        blocked, = described_class.detect("sudo -s")
        expect(blocked).to be(false)
      end

      it "does NOT flag a lowercase -s cluster (sudo -ks)" do
        blocked, = described_class.detect("sudo -ks")
        expect(blocked).to be(false)
      end
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
