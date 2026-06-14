# frozen_string_literal: true

require "tmpdir"
require "rbconfig"
require "fileutils"

module Rubino
  module Execution
    # OPT-IN OS-level sandbox. Wraps the LocalBackend argv in the platform's
    # unprivileged confinement launcher:
    #
    #   macOS  -> /usr/bin/sandbox-exec with a generated SBPL (.sb) profile.
    #   Linux  -> bwrap (bubblewrap) with bind mounts.
    #
    # The launcher becomes the process-group LEADER (ShellTool still spawns
    # with `pgroup: true`), so killing the group on timeout/cancel kills the
    # whole sandboxed subtree exactly as before.
    #
    # If the OS mechanism is unavailable (no sandbox-exec, no bwrap, or
    # unprivileged userns is blocked) the backend DEGRADES to the inner
    # LocalBackend argv with a one-time visible warning. It never hard-fails —
    # every peer agent degrades the same way.
    class SandboxBackend
      # Always-writable roots on top of the workspace, regardless of mode
      # (except :read_only, which writes nothing). Temp dirs are where build
      # tools, package managers and `mktemp` scratch by default.
      def initialize(mode: :workspace_write, local: LocalBackend.new)
        @mode  = mode
        @local = local
      end

      def argv(command, writable_roots: [])
        inner = @local.argv(command, writable_roots: writable_roots)
        wrapper = build_wrapper(inner, Array(writable_roots))
        return inner unless wrapper # degraded

        wrapper
      end

      def degraded? = !self.class.available?

      # True when this OS exposes an unprivileged sandbox mechanism we can
      # use. macOS: sandbox-exec exists. Linux: bwrap on PATH. Anything else
      # (or a probe failure) is false -> caller degrades to Local.
      def self.available?
        case host_os
        when :macos then File.executable?("/usr/bin/sandbox-exec")
        when :linux then !which("bwrap").nil?
        else false
        end
      end

      def self.host_os
        case RbConfig::CONFIG["host_os"]
        when /darwin/ then :macos
        when /linux/  then :linux
        else :other
        end
      end

      def self.which(bin)
        ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).each do |dir|
          path = File.join(dir, bin)
          return path if File.executable?(path) && !File.directory?(path)
        end
        nil
      end

      private

      # Returns the wrapped argv, or nil to signal "degrade to Local".
      def build_wrapper(inner, roots)
        unless self.class.available?
          warn_degraded
          return nil
        end

        case self.class.host_os
        when :macos then macos_argv(inner, roots)
        when :linux then linux_argv(inner, roots)
        end
      end

      # ---- macOS: sandbox-exec + SBPL ------------------------------------

      def macos_argv(inner, roots)
        profile = write_sb_profile(macos_profile(roots))
        ["/usr/bin/sandbox-exec", "-f", profile, "--", *inner]
      end

      # Generates an SBPL profile: deny writes by default, allow reads broadly,
      # allow writes only to the workspace roots + temp dirs, force ~/.rubino
      # and each .git read-only, deny network unless enabled.
      def macos_profile(roots)
        writable = (@mode == :read_only ? [] : roots + temp_roots)
        lines = ["(version 1)", "(deny default)", "(allow process*)",
                 "(allow sysctl-read)", "(allow file-read*)"]
        writable.uniq.each { |p| lines << "(allow file-write* #{sb_subpath(p)})" }
        # Force-deny writes to the secrets home and each repo's .git even if
        # they sit under a writable root.
        readonly_roots(roots).each { |p| lines << "(deny file-write* #{sb_subpath(p)})" }
        lines << network_rule_sb
        "#{lines.join("\n")}\n"
      end

      def network_rule_sb
        Backend.network_enabled? ? "(allow network*)" : "(deny network*)"
      end

      def sb_subpath(path)
        %{(subpath "#{File.expand_path(path)}")}
      end

      def write_sb_profile(contents)
        dir = File.join(Dir.tmpdir, "rubino-sandbox")
        FileUtils.mkdir_p(dir)
        path = File.join(dir, "profile_#{Process.pid}_#{rand(1_000_000)}.sb")
        File.write(path, contents)
        path
      end

      # ---- Linux: bwrap --------------------------------------------------

      def linux_argv(inner, roots)
        # --ro-bind / / makes the whole filesystem readable but read-only;
        # writable access is then re-granted per directory below. --dev/--proc
        # give a clean /dev and /proc. We deliberately do NOT --tmpfs /tmp:
        # /tmp is added as a writable --bind via temp_roots (workspace_write),
        # and left read-only (under --ro-bind /) in read_only mode.
        args = ["bwrap", "--die-with-parent", "--ro-bind", "/", "/",
                "--dev", "/dev", "--proc", "/proc"]
        unless @mode == :read_only
          (roots + temp_roots).uniq.each { |p| args += ["--bind", p, p] if File.exist?(p) }
        end
        # Re-impose read-only on the secrets home and each .git.
        readonly_roots(roots).each { |p| args += ["--ro-bind", p, p] if File.exist?(p) }
        args << "--unshare-net" unless Backend.network_enabled?
        [*args, *inner]
      end

      # ---- shared --------------------------------------------------------

      # Temp dirs every mode (except read_only) may write to.
      def temp_roots
        [
          "/tmp",
          ENV.fetch("TMPDIR", nil),
          File.join(Dir.tmpdir, "rubino-sandbox")
        ].compact.map { |p| File.expand_path(p) }
      end

      # Paths that must stay read-only even inside a writable root: the
      # secrets/state home (~/.rubino) and every repo's .git directory.
      def readonly_roots(roots)
        out = [Rubino.home_path]
        roots.each do |r|
          git = File.join(r, ".git")
          out << git if File.directory?(git)
        end
        out.map { |p| File.expand_path(p) }
      end

      def warn_degraded
        return if self.class.warned?

        self.class.mark_warned!
        Rubino.ui&.warning(
          "execution.sandbox is enabled but no OS sandbox mechanism is " \
          "available here (#{degrade_reason}); running UNSANDBOXED. " \
          "Install bubblewrap (Linux) or run on macOS to enable confinement."
        )
      rescue StandardError
        nil
      end

      def degrade_reason
        case self.class.host_os
        when :macos then "/usr/bin/sandbox-exec missing"
        when :linux then "bwrap not on PATH"
        else "unsupported OS"
        end
      end

      class << self
        def warned? = @warned == true
        def mark_warned! = @warned = true
        def reset_warned! = @warned = false
      end
    end
  end
end
