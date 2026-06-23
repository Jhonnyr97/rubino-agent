# frozen_string_literal: true

require "rbconfig"

module Rubino
  module Security
    # OS-level filesystem WRITE jail around the single Process.spawn in
    # shell_tool.rb (#290, #544). The per-command approval allowlist is a UX
    # guard-rail, not a security boundary; this module is the real floor.
    #
    # It returns an argv PREFIX (and a little extra env) to put in front of the
    # `bash -o pipefail -c …` the shell tool already runs:
    #   macOS  → /usr/bin/sandbox-exec -p <SBPL> -D… -- bash …   (Seatbelt)
    #   Linux  → <home>/bin/rubino-landlock -- bash …            (Landlock)
    #   off / unavailable → []  (byte-identical to no sandbox)
    #
    # Asymmetry by design: reads stay broad everywhere (#406); only writes are
    # confined to {workspace roots, $TMPDIR, /tmp, ~/.rubino, /dev/null}.
    #
    # Graceful degradation: when mode != off but no mechanism exists (old
    # kernel, non-mac/linux, helper won't compile) we fail OPEN — empty prefix —
    # and surface a one-time loud banner (see #degraded? / #degradation_notice).
    module Sandbox
      ABS_SANDBOX_EXEC = "/usr/bin/sandbox-exec"

      # The realpathed temp dir + /tmp are always writable (scratch space the
      # toolchain needs); they are NOT a workspace bypass since the threat is
      # writing OUTSIDE the agent's space, and temp is shared scratch.
      module_function

      # :seatbelt | :landlock | :none — memoised per process (the probe runs
      # once, like EnvironmentInspector).
      def available_mechanism
        return @available_mechanism if defined?(@available_mechanism)

        @available_mechanism = detect_mechanism
      end

      # The effective mode: off | read-only | workspace-write. Resolves to :off
      # when config says so OR no mechanism exists (the §4 fail-open path).
      def mode
        configured = configured_mode
        return :off if configured == :off
        return :off if available_mechanism == :none

        configured
      end

      # True when the user asked for a sandbox (config mode != off) but no OS
      # mechanism is available — the fail-open case the banner warns about.
      def degraded?
        configured_mode != :off && available_mechanism == :none
      end

      # One-line reason for the degraded state, or nil when not degraded.
      def degradation_notice
        return nil unless degraded?

        "OS write-sandbox unavailable on this host (no Landlock/Seatbelt); " \
          "shell writes are NOT OS-confined. Approval prompts + the hardline " \
          "floor are the only boundary. See tools.sandbox.mode."
      end

      # Short status string for /status: e.g. "workspace-write (seatbelt)",
      # "off", or "OFF (unavailable)".
      def status_summary
        return "OFF (unavailable)" if degraded?
        return "off" if mode == :off

        "#{mode} (#{available_mechanism})"
      end

      # The argv prefix to splice before `bash …`. [] when off/unavailable.
      def command_prefix(cwd: nil)
        return [] if mode == :off

        case available_mechanism
        when :seatbelt then seatbelt_prefix(cwd: cwd)
        when :landlock then landlock_prefix
        else []
        end
      end

      # Extra env merged into the spawn. Landlock receives the writable roots
      # here (never on argv, so a path with spaces/quotes is safe); Seatbelt
      # passes them as -D params, so it needs none.
      def extra_env(cwd: nil)
        return {} unless mode != :off && available_mechanism == :landlock

        { "RUBINO_SANDBOX_WRITABLE_ROOTS" => landlock_roots_env(cwd: cwd) }
      end

      # The de-duped, existing absolute paths the jail allows writes to. The
      # workspace set is read live from Workspace.canonical_roots, so an
      # --add-dir mid-session is reflected on the next shell call; `cwd` is
      # accepted for symmetry with the public API and future per-cwd derivation.
      def writable_roots(cwd: nil) # rubocop:disable Lint/UnusedMethodArgument
        roots = []
        roots.concat(Workspace.canonical_roots) unless mode == :"read-only"
        roots.concat(temp_roots)
        roots << canonical(Rubino.home_path)
        roots.concat(extra_writable.filter_map { |p| canonical(p) })
        roots.compact.uniq.select { |p| File.directory?(p) }
      end

      # Test/teardown hook — drop the memoised probe so a stubbed platform takes
      # effect in the next example.
      def reset!
        remove_instance_variable(:@available_mechanism) if defined?(@available_mechanism)
        remove_instance_variable(:@landlock_helper) if defined?(@landlock_helper)
      end

      # ---- mechanism detection -------------------------------------------

      def detect_mechanism
        case RbConfig::CONFIG["host_os"]
        when /darwin/
          File.executable?(ABS_SANDBOX_EXEC) ? :seatbelt : :none
        when /linux/
          landlock_helper ? :landlock : :none
        else
          :none
        end
      end
      private_class_method :detect_mechanism

      def configured_mode
        raw = Rubino.configuration&.dig("tools", "sandbox", "mode").to_s
        %w[off read-only workspace-write].include?(raw) ? raw.to_sym : :"workspace-write"
      rescue StandardError
        :"workspace-write"
      end
      private_class_method :configured_mode

      def extra_writable
        Array(Rubino.configuration&.dig("tools", "sandbox", "extra_writable"))
      rescue StandardError
        []
      end
      private_class_method :extra_writable

      # ---- macOS / Seatbelt ----------------------------------------------

      def seatbelt_prefix(cwd:)
        roots = writable_roots(cwd: cwd)
        defines = []
        roots.each_with_index { |r, i| defines << "-DWRITABLE_ROOT_#{i}=#{r}" }
        [ABS_SANDBOX_EXEC, "-p", seatbelt_policy(roots.size), *defines, "--"]
      end
      private_class_method :seatbelt_prefix

      # default-deny base (lifted from Codex seatbelt_base_policy.sbpl) + broad
      # reads + open network (slice 1) + a write rule per parameterised root.
      # Literal paths are passed only as -D params, never interpolated here, so
      # a path with a `"`/`)` cannot break out of the policy text.
      def seatbelt_policy(root_count)
        writes = (0...root_count).map do |i|
          "(allow file-write* (subpath (param \"WRITABLE_ROOT_#{i}\")))"
        end.join("\n")

        <<~SBPL
          (version 1)
          (deny default)

          (allow process-exec)
          (allow process-fork)
          (allow signal (target same-sandbox))
          (allow process-info* (target same-sandbox))
          (allow file-write-data (require-all (path "/dev/null") (vnode-type CHARACTER-DEVICE)))
          (allow sysctl-read)
          (allow mach-lookup)
          (allow ipc-posix-sem)
          (allow pseudo-tty)
          (allow file-read* file-write* file-ioctl (literal "/dev/ptmx"))
          (allow file-read* file-write* (require-all (regex #"^/dev/ttys[0-9]+") (extension "com.apple.sandbox.pty")))
          (allow file-ioctl (regex #"^/dev/ttys[0-9]+"))
          (allow user-preference-read)

          ; READS: broad (keeps clone-and-inspect / reading sibling repos, #406)
          (allow file-read*)

          ; NETWORK: allowed in slice 1
          (allow network*)
          (allow system-socket)

          ; WRITES: deny everywhere, allow only the parameterised roots
          #{writes}
        SBPL
      end
      private_class_method :seatbelt_policy

      # ---- Linux / Landlock ----------------------------------------------

      def landlock_prefix
        helper = landlock_helper
        helper ? [helper, "--"] : []
      end
      private_class_method :landlock_prefix

      # Newline-joined (NOT NUL: an env var terminates at the first NUL) writable
      # roots for the helper. A path containing a newline is dropped — it could
      # smuggle a spurious root past the separator.
      def landlock_roots_env(cwd:)
        writable_roots(cwd: cwd).reject { |p| p.include?("\n") }.join("\n")
      end
      private_class_method :landlock_roots_env

      # Absolute path to a usable `rubino-landlock`, compiling it on demand into
      # <home>/bin/ and caching the result (nil ⇒ Linux mechanism unavailable →
      # fail open). Memoised; only ever runs the build once per process.
      def landlock_helper
        return @landlock_helper if defined?(@landlock_helper)

        @landlock_helper = resolve_landlock_helper
      end
      private_class_method :landlock_helper

      def resolve_landlock_helper
        # 1) A binary shipped/compiled by the gem's extension build, next to exe.
        shipped = File.expand_path("../../../exe/rubino-landlock", __dir__)
        return shipped if File.executable?(shipped)

        # 2) A previously compiled cache under <home>/bin.
        cached = File.join(Rubino.home_path, "bin", "rubino-landlock")
        return cached if File.executable?(cached)

        # 3) Compile it now from the gem source, if a compiler + headers exist.
        compile_landlock_helper(cached)
      rescue StandardError
        nil
      end
      private_class_method :resolve_landlock_helper

      def compile_landlock_helper(dest)
        src = File.expand_path("../../../ext/landlock/landlock.c", __dir__)
        return nil unless File.file?(src)

        cc = ENV.fetch("CC", "").empty? ? "cc" : ENV.fetch("CC")
        return nil unless system("command -v #{cc} > /dev/null 2>&1")

        require "fileutils"
        FileUtils.mkdir_p(File.dirname(dest))
        ok = system(cc, "-O2", "-o", dest, src,
                    out: File::NULL, err: File::NULL)
        ok && File.executable?(dest) ? dest : nil
      rescue StandardError
        nil
      end
      private_class_method :compile_landlock_helper

      # ---- shared helpers -------------------------------------------------

      def temp_roots
        [ENV.fetch("TMPDIR", nil), "/tmp"].filter_map { |p| canonical(p) }
      end
      private_class_method :temp_roots

      def canonical(path)
        return nil if path.nil? || path.to_s.empty?

        File.realpath(File.expand_path(path.to_s))
      rescue StandardError
        nil
      end
      private_class_method :canonical
    end
  end
end
