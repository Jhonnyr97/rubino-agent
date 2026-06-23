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
    #   Linux  → <gem>/ext/landlock/rubino-landlock -- bash …    (Landlock)
    #   off / unavailable → []  (byte-identical to no sandbox)
    #
    # Asymmetry by design: reads stay broad everywhere (#406); only writes are
    # confined to {workspace roots, $TMPDIR, /tmp, /dev/null}.
    #
    # ~/.rubino is DELIBERATELY NOT writable from the jailed shell: it holds the
    # sandbox's own trust anchors (the resolved helper binary, config.yml, .env,
    # the session DB, skills/, commands/). The agent persists all of those in
    # the Ruby PROCESS, never by spawning the shell tool's bash — so confining
    # the shell out of ~/.rubino loses no legitimate capability while closing
    # the self-tamper persistence escape (helper/config poisoning).
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

      # True when the OS write-jail mechanism is PRESENT and configured on (mode
      # != off AND a Seatbelt/Landlock mechanism exists). This is a PRESENCE
      # check only — it does NOT prove the mechanism actually confines writes at
      # runtime (the Landlock helper fails OPEN on a kernel without enforcement).
      # Use it for the banner/status posture; the SECURITY-relaxation decision
      # (slice 2 Part C) must use #enforcing? instead. False under degraded?
      # (requested but no mechanism) and under mode == :off.
      def active?
        mode != :off && available_mechanism != :none
      end

      # True ONLY when the OS write-jail is PROVEN to confine writes at runtime.
      # active? checks the mechanism is PRESENT; this runs the real launcher once
      # against a throwaway command that tries to write a file OUTSIDE a writable
      # root and returns true only if that write was DENIED. Closes the
      # "helper present but Landlock not enforcing (fails open)" gap: a binary
      # that execs unconfined produces the probe file ⇒ enforcing? == false.
      # Memoised — one spawn at first use, like the mechanism probe.
      #
      # This is the predicate the approval layer gates the conditional allowlist
      # relaxation on (slice 2 Part C): only relax the pure-WRITE flag-forms when
      # the jail DEMONSTRABLY confines them. When present-but-not-enforcing the
      # state is DEGRADED and the broad prompt stays.
      def enforcing?
        return @enforcing if defined?(@enforcing)

        @enforcing = active? && probe_enforcement
      end

      # True when a sandbox mechanism is configured+present but does NOT actually
      # enforce at runtime (helper fails open / kernel lacks Landlock). In this
      # state writes are unconfined despite the mechanism appearing available, so
      # callers must keep the broad write screen and say so honestly.
      def present_but_not_enforcing?
        active? && !enforcing?
      end

      # True when the operator opted into FAIL-CLOSED: tools.sandbox.require.
      # When set AND no mechanism exists, shell execution must REFUSE rather
      # than fall open (slice 2 Part B). Default false (fail-open, §4).
      def required?
        raw = Rubino.configuration&.dig("tools", "sandbox", "require")
        raw == true || raw.to_s == "true"
      rescue StandardError
        false
      end

      # nil when the shell may run; otherwise a one-line refusal message. Refuses
      # ONLY when the operator REQUIRES the sandbox but no mechanism can enforce
      # it (required? && available_mechanism == :none) — the fail-closed path the
      # foreground and background shell spawns both consult before launching.
      # When a mechanism IS available (or require is off) this returns nil and
      # execution proceeds as before.
      def refusal_reason
        return nil unless required? && available_mechanism == :none

        "sandbox required but unavailable on this host — " \
          "set tools.sandbox.require=false to run unconfined"
      end

      # Short status string for /status: e.g. "workspace-write (seatbelt)",
      # "off", or "OFF (unavailable)". Appends the enforcement posture
      # (required vs best-effort) so the operator can tell a fail-closed
      # require:true config from the fail-open default at a glance.
      def status_summary
        return required? ? "OFF (unavailable, required)" : "OFF (unavailable)" if degraded?
        return "off" if mode == :off

        "#{mode} (#{available_mechanism}, #{required? ? "required" : "best-effort"})"
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

      # Jail ANY argv (not just bash): prepend the launcher prefix so every
      # process-spawning tool (shell, ruby, run_tests) goes through the same OS
      # write-jail. [] prefix when off/unavailable ⇒ byte-identical to no
      # sandbox. Callers splat the result into Process.spawn/Open3 and merge
      # #wrap_env into their env. `argv` is the already-built command argv.
      def wrap_argv(argv, cwd: nil)
        [*command_prefix(cwd: cwd), *argv]
      end

      # The extra env every wrapped spawn must merge (writable roots for
      # Landlock; {} for Seatbelt/off). Alias of #extra_env for symmetry with
      # #wrap_argv at the call sites.
      def wrap_env(cwd: nil)
        extra_env(cwd: cwd)
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
        roots.concat(extra_writable.filter_map { |p| canonical(p) })
        roots.compact.uniq.select { |p| File.directory?(p) }
      end

      # The one-line attribution appended to a tool's output when an EACCES it
      # surfaced is actually the OS write-jail denying a write OUTSIDE the
      # writable roots (#74). Without it a jailed write reads like an ordinary
      # perms error and the model misattributes it (chmod/sudo loops) instead of
      # writing inside the workspace.
      WRITE_JAIL_HINT =
        "(blocked by the workspace write-jail — tools.sandbox; write inside the workspace)"

      # Detects the OS-deny shape, capturing the offending path. EACCES from a
      # write outside the jail surfaces as "Permission denied @ ... - /abs/path"
      # (Ruby Errno) or "<path>: Permission denied" (shell tools).
      DENIED_PATH = %r{
        (?:Permission\ denied|EACCES|Operation\ not\ permitted)
        .*?(/[^\s'"`:]+)
        |
        (/[^\s'"`:]+)\s*:?\s*(?:Permission\ denied|Operation\ not\ permitted)
      }xi

      # Returns the attribution hint when +text+ carries an EACCES/"Permission
      # denied" against a path that is OUTSIDE the writable roots while the jail
      # is PROVEN to be enforcing; nil otherwise. Only fires under #enforcing? so
      # an unconfined host (no/degraded sandbox) never mislabels a genuine perms
      # error as a jail denial. A normal perms failure INSIDE the workspace is
      # not a jail block, so it returns nil too. Best-effort: any parse/probe
      # error yields nil (no hint) rather than raising into a tool's output.
      def write_jail_attribution(text, cwd: nil)
        return nil if text.to_s.empty?
        return nil unless enforcing?

        roots = writable_roots(cwd: cwd)
        text.to_s.scan(DENIED_PATH).each do |groups|
          path = groups.compact.first
          next unless path

          target = canonical(path) || File.expand_path(path)
          return WRITE_JAIL_HINT unless inside_roots?(target, roots)
        end
        nil
      rescue StandardError
        nil
      end

      # True when +target+ resolves under any of +roots+ (a writable location).
      def inside_roots?(target, roots)
        roots.any? do |root|
          target == root || target.start_with?("#{root}#{File::SEPARATOR}")
        end
      end
      private_class_method :inside_roots?

      # Test/teardown hook — drop the memoised probe so a stubbed platform takes
      # effect in the next example.
      def reset!
        remove_instance_variable(:@available_mechanism) if defined?(@available_mechanism)
        remove_instance_variable(:@landlock_helper) if defined?(@landlock_helper)
        remove_instance_variable(:@enforcing) if defined?(@enforcing)
      end

      # ---- runtime enforcement self-test --------------------------------

      # Run the REAL launcher once on a throwaway command that tries to write a
      # file OUTSIDE the (single, throwaway) writable root we grant it. Returns
      # true ONLY if the write was DENIED (probe file absent). A mechanism that
      # fails open execs the command unconfined ⇒ the probe file appears ⇒ false.
      #
      # We must NOT reuse the live writable roots (they include /tmp + TMPDIR, so
      # any temp-dir probe target would be legitimately granted): we build a
      # probe-specific prefix that grants ONLY a fresh writable root, then target
      # a sibling dir that is provably outside it. Any spawn/setup error fails
      # SAFE (false → no relaxation). One spawn; memoised by #enforcing?.
      def probe_enforcement
        require "tmpdir"
        require "open3"
        require "shellwords"

        Dir.mktmpdir("rubino-sbx") do |base|
          root    = File.join(base, "root")
          outside = File.join(base, "outside")
          Dir.mkdir(root)
          Dir.mkdir(outside)
          probe = File.join(outside, "probe")

          prefix, env = probe_launcher(root)
          return false if prefix.empty? # no real mechanism ⇒ nothing enforces

          argv = [*prefix, "bash", "-c", ": > #{probe.shellescape}"]
          Open3.capture3(env, *argv)
          !File.exist?(probe) # DENY (absent) ⇒ enforcing
        end
      rescue StandardError
        false
      end
      private_class_method :probe_enforcement

      # The launcher prefix + env that confine writes to EXACTLY `root` (one
      # throwaway dir), used only by #probe_enforcement so the probe's "outside"
      # target is unambiguously not granted. Mirrors command_prefix/extra_env but
      # with a fixed single root instead of the live writable set.
      def probe_launcher(root)
        case available_mechanism
        when :seatbelt
          [[ABS_SANDBOX_EXEC, "-p", seatbelt_policy(1), "-DWRITABLE_ROOT_0=#{root}", "--"], {}]
        when :landlock
          helper = landlock_helper
          return [[], {}] unless helper

          [[helper, "--"], { "RUBINO_SANDBOX_WRITABLE_ROOTS" => root }]
        else
          [[], {}]
        end
      end
      private_class_method :probe_launcher

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

      # Absolute path to a usable `rubino-landlock`, or nil (⇒ Linux mechanism
      # unavailable → fail open). Memoised; resolved once per process.
      def landlock_helper
        return @landlock_helper if defined?(@landlock_helper)

        @landlock_helper = resolve_landlock_helper
      end
      private_class_method :landlock_helper

      # SECURITY: the helper is the trust anchor the jail execs in front of bash,
      # so it MUST come from a location the jailed shell cannot write. We resolve
      # ONLY from the gem's installed extension build dir (ext/landlock/, built by
      # the gemspec extension at `gem install` time) — never from a writable cache
      # under ~/.rubino, which the confined shell could overwrite to neuter the
      # next run. Absent (helper not built) ⇒ nil ⇒ graceful fail-open + banner.
      def resolve_landlock_helper
        built = File.expand_path("../../../ext/landlock/rubino-landlock", __dir__)
        File.executable?(built) ? built : nil
      rescue StandardError
        nil
      end
      private_class_method :resolve_landlock_helper

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
