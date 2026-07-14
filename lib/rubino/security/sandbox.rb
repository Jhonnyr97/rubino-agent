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
      #
      # escalate:true is the approved out-of-jail run (the `disable_sandbox`
      # shell param, §B). It drops the OS jail entirely: the approval prompt
      # (step 4b) is the only boundary. The ~/.rubino trust anchors are NOT
      # OS-protected during an approved escalation — the human decides.
      def command_prefix(cwd: nil, escalate: false)
        return [] if mode == :off
        return escalated_prefix if escalate

        case available_mechanism
        when :seatbelt then seatbelt_prefix(cwd: cwd)
        when :landlock then landlock_prefix
        else []
        end
      end

      # Jail ANY argv (not just bash): prepend the launcher prefix so every
      # process-spawning tool (shell, ruby) goes through the same OS
      # write-jail. [] prefix when off/unavailable ⇒ byte-identical to no
      # sandbox. Callers splat the result into Process.spawn/Open3 and merge
      # #wrap_env into their env. `argv` is the already-built command argv.
      def wrap_argv(argv, cwd: nil, escalate: false)
        [*command_prefix(cwd: cwd, escalate: escalate), *argv]
      end

      # The extra env every wrapped spawn must merge (writable roots for
      # Landlock; {} for Seatbelt/off). Alias of #extra_env for symmetry with
      # #wrap_argv at the call sites.
      def wrap_env(cwd: nil, escalate: false)
        extra_env(cwd: cwd, escalate: escalate)
      end

      # Extra env merged into the spawn. Landlock receives the writable roots
      # here (never on argv, so a path with spaces/quotes is safe); Seatbelt
      # passes them as -D params, so it needs none. An escalated run needs none
      # either: Seatbelt carves the anchors out via -D params, and Landlock
      # escalation is unconfined (empty prefix, no roots).
      def extra_env(cwd: nil, escalate: false)
        return {} if mode == :off || escalate
        return {} unless available_mechanism == :landlock

        { "RUBINO_SANDBOX_WRITABLE_ROOTS" => landlock_roots_env(cwd: cwd) }
      end

      # The operator's escalation posture (config tools.sandbox.escalation),
      # governing what the `disable_sandbox` out-of-jail escape hatch does:
      #   :off           — no escape hatch; the flag is ignored and a jailed
      #                    write hard-fails (Claude allowUnsandboxedCommands:false
      #                    / Codex Never).
      #   :"protect-home"— DEFAULT. Escalation runs broadly BUT the ~/.rubino
      #                    trust anchors stay OS-refused (Seatbelt carve-out;
      #                    Landlock can't express it → approval-only there).
      #   :full          — Codex-style: an approved escalation is fully unconfined
      #                    (SandboxType::None); the human approval is the only
      #                    boundary. No OS floor on ~/.rubino.
      # Unknown/absent ⇒ the secure default. Independent of #required? (that
      # governs fail-open vs -closed when NO mechanism exists; this governs the
      # escape hatch when one does).
      def escalation_mode
        # YAML parses a bare `off`/`no` as the boolean false (and `on` as true),
        # so an operator who writes `escalation: off` yields false here — map that
        # (and the string forms) to :off, otherwise a disabled hatch would
        # silently read as the protect-home default.
        case Rubino.configuration&.dig("tools", "sandbox", "escalation").to_s
        when "off", "false", "no" then :off
        when "full" then :full
        else :"protect-home"
        end
      rescue StandardError
        :"protect-home"
      end

      # Whether the escape hatch is available at all (any mode but :off). Read by
      # the shell tool (advertise the param / honour the flag), the approval
      # policy (route to :ask), and #escalated_prefix.
      def escalation_allowed?
        escalation_mode != :off
      end

      # Under protect-home the ~/.rubino floor is held ONLY by the approval
      # prompt on EVERY platform — we no longer OS-block it on Seatbelt, so the
      # human decides, not the sandbox. The approval card surfaces this honestly.
      # False in :full (no floor intended) and everywhere now (no platform degrades).
      def escalation_degrades_on_linux?
        false
      end

      # The one-line disclosure the approval card shows for an escalation prompt,
      # honest about what the approval actually grants under the active mode.
      def escalation_disclosure
        case escalation_mode
        when :full
          "runs OUTSIDE the OS write-jail (tools.sandbox) — FULL filesystem access, ~/.rubino NOT protected"
        when :"protect-home"
          "runs OUTSIDE the OS write-jail (tools.sandbox); ~/.rubino protected by approval only"
        else
          "runs OUTSIDE the OS write-jail (tools.sandbox)"
        end
      end

      # True when tools.sandbox.devices.<name>.mode is set to deny (YAML parses a
      # bare `deny`/`no`/`off`/`false` here). A device is enabled by default —
      # device access (GPU/Metal via IOKit) is not a security boundary worth a
      # per-command gate (it grants no filesystem write nor extra network; the
      # write-jail stays ON), so the only knob is this global deny.
      def device_denied?(name)
        mode = Rubino.configuration&.dig("tools", "sandbox", "devices", name.to_s, "mode").to_s
        %w[deny no off false].include?(mode)
      rescue StandardError
        false
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

      # Clause appended when the escape hatch is open: the model can re-issue the
      # SAME shell command with disable_sandbox:true to REQUEST approval to run
      # it outside the jail (§B). Not advertised when escalation is disabled.
      ESCALATE_CLAUSE =
        "or re-run the shell command with disable_sandbox:true to request approval to run it outside the jail"

      # Hint for a denied write that lands INSIDE the agent-home trust anchors
      # (e.g. ~/.rubino/skills/…): steer the model to the in-process path instead
      # of a shell write. True in every escalation mode — skills are managed via
      # the tool, not a jailed/escalated shell rm (and under protect-home an
      # escalation wouldn't reach here anyway).
      TRUST_ANCHOR_HINT =
        "(the agent home ~/.rubino holds rubino's own config/skills/DB — manage skills with the " \
        "`skill` tool: action create/edit/patch/delete, not a shell write)"

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
          return hint_for(target) unless inside_roots?(target, roots)
        end
        nil
      rescue StandardError
        nil
      end

      # The right attribution for a jailed write to +target+: the trust-anchor
      # hint when it lands under ~/.rubino (escalation won't help — use the skill
      # tool), the escalation-aware hint when the escape hatch is open, else the
      # plain write-inside-the-workspace hint.
      def hint_for(target)
        return TRUST_ANCHOR_HINT if inside_roots?(target, trust_anchor_roots)
        return "#{WRITE_JAIL_HINT[0..-2]} — #{ESCALATE_CLAUSE})" if escalation_allowed?

        WRITE_JAIL_HINT
      end
      private_class_method :hint_for

      # True when +path+ resolves under one of the current writable roots — i.e.
      # a write there would NOT be blocked by the jail. Public so callers that
      # already hold a concrete path (e.g. the DB-open read-only attribution,
      # #Y2A) can ask directly instead of pattern-matching an error string. The
      # path is canonicalized the SAME way the roots are (realpath, resolving the
      # nearest EXISTING ancestor for a not-yet-created file) so a symlinked
      # parent like macOS's /var → /private/var doesn't read as "outside".
      def writable?(path, cwd: nil)
        inside_roots?(canonical_existing(path), writable_roots(cwd: cwd))
      end

      # realpath of +path+ when it exists, else realpath of its nearest existing
      # ancestor with the missing tail re-appended, else a plain expand_path.
      def canonical_existing(path)
        abs = File.expand_path(path.to_s)
        dir = abs
        dir = File.dirname(dir) while !File.exist?(dir) && File.dirname(dir) != dir
        real = (File.realpath(dir) if File.exist?(dir))
        real ? abs.sub(/\A#{Regexp.escape(dir)}/, real) : abs
      end
      private_class_method :canonical_existing

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
        [ABS_SANDBOX_EXEC, "-p", seatbelt_policy(roots.size, device_clients: enabled_device_clients), *defines, "--"]
      end
      private_class_method :seatbelt_prefix

      # The sanitized IOKit user-client rules for EVERY non-denied device in
      # tools.sandbox.devices — appended to the Seatbelt profile so GPU/Metal
      # (MLX, MPS) just works, with the write-jail unchanged. [] when the map is
      # absent/empty or all devices are denied.
      def enabled_device_clients
        devices = Rubino.configuration&.dig("tools", "sandbox", "devices")
        return [] unless devices.is_a?(Hash)

        devices.keys.flat_map { |name| device_iokit_clients(name) }.uniq
      rescue StandardError
        []
      end
      private_class_method :enabled_device_clients

      # The escalated (disable_sandbox) launcher prefix. Only reached when the
      # hatch is open (escalation_allowed?), so the mode here is :full or
      # :"protect-home". Both run UNCONFINED — the approval prompt (step 4b) is
      # the only boundary. protect-home no longer OS-blocks ~/.rubino on any
      # platform: the human decides, not the sandbox.
      def escalated_prefix
        []
      end
      private_class_method :escalated_prefix

      # The agent-home dir(s) (config.yml/.env/session DB/helper/skills).
      # Used only by the write-jail attribution hint, not for OS enforcement
      # during escalation. Skills under here are managed via the `skill` tool
      # (in-process), never a jailed shell write.
      def trust_anchor_roots
        home = canonical(agent_home) || File.expand_path(agent_home)
        [home].compact.select { |p| File.directory?(p) }
      end
      private_class_method :trust_anchor_roots

      def agent_home
        Config::Loader.default_home_path
      rescue StandardError
        File.expand_path("~/.rubino")
      end
      private_class_method :agent_home

      # default-deny base (lifted from Codex seatbelt_base_policy.sbpl) + broad
      # reads + open network. Literal paths are passed only as -D params, never
      # interpolated, so a path with a `"`/`)` cannot break out of the text. The
      # write rules are appended by the two composers below.
      def seatbelt_base_policy
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
        SBPL
      end
      private_class_method :seatbelt_base_policy

      # WORKSPACE-WRITE: deny writes everywhere, allow only the parameterised
      # roots (the default confinement). When device_clients are given, appends
      # the IOKit user-client rules AFTER the write rules (order-independent).
      def seatbelt_policy(root_count, device_clients: [])
        writes = (0...root_count).map do |i|
          "(allow file-write* (subpath (param \"WRITABLE_ROOT_#{i}\")))"
        end.join("\n")

        "#{seatbelt_base_policy}\n; WRITES: deny everywhere, allow only the parameterised roots\n#{writes}\n#{seatbelt_device_rules(device_clients)}"
      end
      private_class_method :seatbelt_policy

      # The device user-client lines to append to the Seatbelt profile when
      # the named device is granted. Returns "" when clients is empty.
      def seatbelt_device_rules(clients)
        return "" if clients.empty?

        lines = clients.map { |c| " (iokit-user-client-class \"#{c}\")" }
        "; DEVICE: GPU/Metal user-clients (write-jail unchanged)\n" \
          "(allow iokit-open-user-client\n#{lines.join("\n")})\n" \
          "(allow iokit-get-properties)\n"
      end
      private_class_method :seatbelt_device_rules

      # SECURITY-CRITICAL: these strings are interpolated INTO the SBPL policy
      # text. Sanitize: keep ONLY entries matching /\A[A-Za-z0-9_]+\z/ — drop
      # anything with quotes/parens/whitespace/newlines to prevent SBPL injection.
      # Dedup. Returns [] on any error or when the device is deny/absent.
      def device_iokit_clients(name)
        entry = Rubino.configuration&.dig("tools", "sandbox", "devices", name.to_s)
        return [] unless entry
        return [] if device_denied?(name)

        Array(entry["iokit_user_clients"])
          .map(&:to_s)
          .select { |c| c.match?(/\A[A-Za-z0-9_]+\z/) }
          .uniq
      rescue StandardError
        []
      end
      private_class_method :device_iokit_clients



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
