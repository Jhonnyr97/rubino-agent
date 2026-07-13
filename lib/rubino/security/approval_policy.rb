# frozen_string_literal: true

require "shellwords"

module Rubino
  module Security
    # Determines whether a tool execution requires user approval.
    # Uses pattern-based rules, tool risk levels, and doom loop detection.
    #
    # Config example:
    #   approvals:
    #     mode: "manual"  # manual | auto | skip
    #   permissions:
    #     "git *": "allow"
    #     "shell rm *": "deny"
    #     "shell bundle *": "allow"
    #     "file_system write ~/.env": "deny"
    class ApprovalPolicy
      MODES = %w[manual auto skip].freeze

      # Structured in-workspace file-edit tools. Under dangerous_only these run
      # unprompted — SYMMETRIC with safe shell — because the always-on #413
      # write-denylist + workspace sandbox (both enforced inside the tool's
      # #call, regardless of approval) are the boundary, not a per-edit prompt
      # (#427, mirrors Hermes file_safety + Claude Code acceptEdits / Codex
      # auto-edit / aider).
      STRUCTURED_EDIT_TOOLS = %w[edit write multi_edit apply_patch].freeze

      # File tools whose WRITE TARGET path is run through the secret-file gate.
      # WRITE side resolves the path from `file_path` (apply_patch from its patch
      # text, see #secret_file_access?). The READ side (read/grep/glob) is NOT
      # gated: reading a secret is allowed unprompted, matching the field norm
      # (Claude Code / Codex / aider / Windsurf / LangChain all allow secret
      # reads; protection is on write/exec/network, #480). Only writing/editing
      # a secret still requires explicit approval.
      SECRET_GATED_WRITE_TOOLS = STRUCTURED_EDIT_TOOLS

      # Read tools whose target path is checked against the agent home
      # (~/.rubino). Reading config, memories, or session data requires
      # explicit approval — symmetric with the write gate. grep/glob path
      # defaults to "." (the cwd), which is never under the agent home.
      AGENT_HOME_READ_TOOLS = %w[read grep glob].freeze

      # Dedicated code-execution tools that, under dangerous_only, must run
      # unprompted — SYMMETRIC with (and never HARDER than) safe shell.
      #
      # `ruby` evaluates arbitrary code in a sandboxed child process and exposes
      # NO reliable read-only signal, so it cannot be auto-allowed on a proven
      # read-only basis the way step 6b auto-allows parse-validated read-only
      # shell; instead it is aligned AT MOST to the same tier as raw safe shell
      # (auto-run under dangerous_only, never gated harder than the `shell` path
      # it would otherwise be driven through). It was the inversion: a dedicated
      # eval tool prompting while arbitrary safe `shell` ran unprompted, pushing
      # automation toward raw shell. It is :medium and would otherwise fall
      # through to step 9 -> :ask. The hardline floor (step 1), permissions:deny
      # (step 2) and doom guard (step 4) all run first and are unchanged;
      # confirm_all (non-default) still routes it to step 9 -> :ask.
      CODE_EXEC_TOOLS = %w[ruby].freeze

      # Why the most recent #decide returned :deny — :hardline (the
      # non-bypassable floor), :permission_rule (an explicit permissions deny
      # rule), or :doom_loop (the repeated-identical-call guard). nil when the
      # last decision wasn't a deny. ToolExecutor reads this right after
      # #decide to build a reason-specific model-facing denial message, so a
      # policy denial is never reported as "denied by user" (#143).
      attr_reader :last_deny_reason

      # Why the most recent #decide returned :ask, when the reason is one the UI
      # should annotate — currently only :outside_workspace (a structured write
      # whose target sits outside every allowed root, routed to the widen prompt).
      # nil for an ordinary risk/secret/shell :ask. ToolExecutor reads it right
      # after #decide to prepend the "outside the workspace — approving adds the
      # directory" note to the approval card, so the human sees WHY the write is
      # being gated and what approving grants.
      attr_reader :last_ask_reason

      def initialize(config: nil, agent_overrides: nil)
        @config = config || Rubino.configuration
        @mode = @config.dig("approvals", "mode")
        # Effective shell prompt policy (:confirm_all | :dangerous_only), the
        # SOLE source of truth (item 7): security.confirm_policy only — the legacy
        # security.require_confirmation_for_shell alias was removed (see
        # Configuration#confirm_policy). Older config objects that predate the
        # accessor fall back to the reference-faithful :dangerous_only default.
        @confirm_policy =
          @config.respond_to?(:confirm_policy) ? @config.confirm_policy : :dangerous_only
        @pattern_matcher = PatternMatcher.new(
          rules: load_permission_rules(agent_overrides)
        )
        # Doom-loop guard, config-driven (#414). Default WARN-not-block with a
        # higher threshold (Hermes tool_guardrails alignment): a tripped detector
        # under hard_stop:false surfaces a warning but lets the call run.
        @doom_detector = DoomLoopDetector.new(
          threshold: @config.respond_to?(:doom_loop_threshold) ? @config.doom_loop_threshold : DoomLoopDetector::DEFAULT_THRESHOLD,
          hard_stop: @config.respond_to?(:doom_loop_hard_stop?) ? @config.doom_loop_hard_stop? : false
        )
        # Set true after a warn-mode doom-loop hit so ToolExecutor can surface a
        # one-time warning to the model without denying the call. Cleared each
        # #decide and on reset_turn!.
        @doom_loop_warning = false
      end

      # True when the LAST #decide tripped the doom-loop guard in WARN mode
      # (hard_stop off): the call was allowed but the model should be told it is
      # repeating an identical call. ToolExecutor reads this to attach a warning.
      attr_reader :doom_loop_warning

      # Returns the decision for a tool call: :allow, :ask, :deny
      #
      # CANONICAL DECISION ORDER (deny-class checks precede every allow path).
      # Mirrors the reconciled reference ordering:
      #
      #   1. hardline(:deny)            non-bypassable floor BELOW yolo
      #   2. permissions:deny           an explicit deny rule also beats yolo
      #   3. runtime yolo (Modes)      allow-exit (doom still guards it).
      #                                 config approvals.mode: "skip" does NOT
      #                                 take this exit — it is not a headless
      #                                 yolo (see steps 7-9 / #260).
      #   4. doom loop                  break a stuck autopilot
      #   5. permissions:allow / :ask   remaining explicit rules
      #   6. command_allowlist          pre-approved EXACT commands -> :allow
      #                                 (chain-aware, token-boundary; never a
      #                                 prefix of a compound line)
      #   6b. readonly auto-allow       parse-validated read-only shell -> :allow
      #   7-8. confirm_policy shell gate  confirm_all -> :ask; dangerous_only
      #                                 -> :ask only if dangerous?, else :allow.
      #                                 Runs for mode "skip" too, so a write/
      #                                 shell under config "skip" still reaches
      #                                 the headless fail-closed floor (#260).
      #   9. mode fallback             ("skip" -> :ask for risky tools, not :allow)
      #
      # The invariant that makes this slice worth doing: HARDLINE and an
      # explicit permissions:deny BOTH run before any allow path (yolo,
      # permissions:allow, command_allowlist), so neither can be overridden
      # by a fast-path the way yolo used to override deny rules.
      def decide(tool, arguments: {}) # rubocop:disable Metrics/PerceivedComplexity,Metrics/CyclomaticComplexity -- one canonical, deliberately linear deny-before-allow decision ladder; splitting it would scatter the ordering invariant
        arguments = arguments.transform_keys(&:to_sym) if arguments.respond_to?(:transform_keys)

        @last_deny_reason = nil
        @last_ask_reason = nil
        @doom_loop_warning = false
        command_str = self.class.command_string(tool, arguments)

        # 1. Hardline floor — a floor BELOW yolo. Catastrophic, unrecoverable
        #    commands (rm -rf /, mkfs, dd to a raw device, fork bomb,
        #    shutdown/reboot, sudo -S password guessing) are denied
        #    UNCONDITIONALLY: before yolo/skip, before doom, before any
        #    permissions:allow rule or command_allowlist entry. Opting into
        #    yolo trusts the agent with your files, NOT to wipe the disk.
        #    Mirrors the reference approval module (enforced first).
        blocked, = HardlineGuard.detect(command_str)
        return deny_with(:hardline) if blocked

        # 2. Explicit permissions:deny — like hardline, a deny rule is a
        #    deny-class check and must beat every allow path. We evaluate the
        #    pattern rules ONCE here and reuse the result below; only the :deny
        #    verdict short-circuits before yolo. allow/ask wait until after the
        #    yolo allow-exit and the doom guard (steps 3-4) so they keep their
        #    original precedence. Mirrors the deny-before-allow ordering in the
        #    plan (hardline -> permissions:deny -> yolo -> doom -> allow/ask).
        pattern_result = @pattern_matcher.match(tool.name, command_str)
        return deny_with(:permission_rule) if pattern_result == :deny

        # 3. Modes.yolo short-circuits the remaining allow/ask logic. We still
        #    run the doom detector AFTER, because an autopilot stuck in a loop
        #    is the one thing yolo isn't supposed to license.
        if Rubino::Modes.skip_approvals?
          return deny_with(:doom_loop) if doom_loop_blocks?(tool, arguments)

          return :allow
        end

        # 4. Doom loop guard. Blocks only under hard_stop (#414); in the default
        #    warn mode it sets @doom_loop_warning and falls through to the normal
        #    decision so a legitimate repeated call is not hard-denied.
        return deny_with(:doom_loop) if doom_loop_blocks?(tool, arguments)

        # 4b. Sandbox ESCALATION request (shell disable_sandbox:true, §B). Running
        #     OUTSIDE the OS write-jail is inherently privileged, so it ALWAYS
        #     prompts with a FRESH, distinct approval — never auto-allowed on a
        #     readonly/allowlisted/dangerous? basis, and above the step 5-6 allow
        #     fast-paths so an escalated form of an otherwise pre-approved command
        #     still asks. Below yolo (step 3): a --yolo operator opted into full
        #     trust and runs it unprompted — the OS anchor carve-out still guards
        #     ~/.rubino even then. Hardline (step 1) + permissions:deny (step 2)
        #     already ran, so an escalated `rm -rf /` is still denied. Headless
        #     :ask becomes the #260 fail-closed block. When the operator disabled
        #     the hatch (allow_escalation:false) the shell tool ignores the flag,
        #     so this is false and the command routes through the normal gate.
        if escalated_shell?(tool, arguments)
          @last_ask_reason = :sandbox_escalation
          return :ask
        end

        # 5. Remaining explicit pattern rules (allow / ask). deny was already
        #    handled in step 2. An explicit user permissions rule (allow/ask)
        #    wins over the secret gate below, so a user who wrote
        #    `read /path/.env: allow` is honored.
        return pattern_result if pattern_result

        # 5b. SECRET-FILE WRITE GATE. WRITING/editing (write/edit/multi_edit/
        #     apply_patch) a SECRET path requires EXPLICIT user approval — the
        #     maintainer decision: not a silent allow, not a silent hard-block.
        #     Returns :ask, which the ToolExecutor turns into the approval
        #     dropdown when interactive (approved → the tool writes the secret;
        #     denied → refused) and into a FAIL-CLOSED block when headless
        #     (:noninteractive). Runs ABOVE the allow fast-paths (steps 6/6b/9)
        #     and BELOW yolo (step 3) so a --yolo operator who opted into full
        #     file trust isn't re-prompted.
        #
        #     READING a secret (read/grep/glob) is NOT gated here —
        #     SecretPath.read_block_error refuses the project-local .env family
        #     and the $HOME credential stores OUTSIDE the agent home (~/.ssh,
        #     ~/.aws, ~/.kube, ~/.docker, ~/.gnupg, ~/.azure, ~/.config/gh,
        #     .netrc, .git-credentials); EVERYTHING under ~/.rubino is handled
        #     by the step-5c gate below.
        return :ask if secret_file_access?(tool, arguments)

        # 5c. AGENT-HOME READ GATE. THE RULE: every read under ~/.rubino
        #     requires EXPLICIT APPROVAL, never an auto-deny.
        #     SecretPath.read_block_error short-circuits to nil for paths under
        #     the agent home so the human decides here. Structured reads
        #     (read/grep/glob) are gated; the skill tool `load` reads SKILL.md
        #     in-process and is NOT gated here (it's the primary skill-loading
        #     path). The shell tool can still `cat ~/.rubino/*` unprompted
        #     (defense-in-depth, like the SecretPath read-block). Runs BELOW
        #     yolo (step 3) so a --yolo operator opted into full trust is never
        #     re-prompted.
        return :ask if agent_home_read?(tool, arguments)

        # 6. Config allowlist of pre-approved commands. Checked AFTER deny
        #    patterns (deny always wins) but BEFORE mode-based decision so a
        #    listed command never triggers a manual prompt.
        return :allow if command_pre_approved?(command_str)

        # 6b. Built-in read-only auto-allow — the same allowlist seam as
        #    step 6, just with a parse-validated built-in set instead of
        #    user-configured prefixes. Runs BELOW the hardline floor (step 1)
        #    and permissions:deny (step 2), so the floor always wins even for
        #    commands added via approvals.readonly_commands. A line the
        #    validator cannot prove read-only falls through to the prompt.
        return :allow if readonly_auto_allowed?(tool, command_str)

        # 6c. skill(action: "create") WRITES <RUBINO_HOME>/skills/<name>/SKILL.md
        #    and must not be a silent low-risk allow (#405): the skill tool stays
        #    :low so a read_only agent keeps `skill load/list/show`, but the
        #    create action is a write and routes to :ask here — like any write.
        #    Below yolo (step 3), so a full-access --yolo agent still creates
        #    skills inline; a headless read_only subagent's :ask becomes the
        #    fail-closed block, closing the unapproved-write path. load is never
        #    gated (only the create action matches).
        #
        #    This gate is now a real boundary, not theater (SK-2): authored
        #    skills are written under the agent HOME (outside the cwd workspace),
        #    so the model can't sidestep it by emitting a plain `write` of the
        #    same SKILL.md — the workspace sandbox (within_workspace?) refuses any
        #    write outside the workspace, leaving this :ask-gated helper as the
        #    ONLY way to author a skill.
        return :ask if skill_write?(tool, arguments)

        # 7-8. confirm_policy gate for a shell command not otherwise resolved.
        #    NOT under runtime yolo (handled at step 3) — that is the explicit
        #    CLI operator override that means "stop prompting me".
        #
        #    config approvals.mode: "skip" is NOT given the same allow-exit as
        #    runtime yolo here. #260 deliberately made the headless skip a
        #    CLI-only opt-in (--yolo): a config-file "skip" must NOT silently
        #    auto-run write/shell in a headless session. So a not-otherwise-
        #    resolved shell command still routes through this gate to :ask, and
        #    the ToolExecutor's headless fail-closed floor (#260) turns that
        #    :ask into a block when there is no interactive session. Interactive
        #    sessions still get a prompt — same as auto/manual. (Reads are
        #    already auto-allowed by step 6b / mode_based_decision, so this
        #    only constrains the write/shell side.)
        #
        #    confirm_all (opt-in hardening)
        #      every such shell command -> :ask. shell is :high risk so manual
        #      mode would ask anyway; this also keeps it gated under auto mode.
        #
        #    dangerous_only (DEFAULT, reference-faithful)
        #      prompt ONLY when the command matches a DangerousPattern
        #      (git push --force, curl|sh, recursive rm of a non-root path,
        #      ...). Safe commands run unprompted. Mirrors approval.py:475
        #      where detect_dangerous_command is the sole prompt trigger.
        #      The hardline floor (step 1) and permissions:deny (step 2) already
        #      ran, so dangerous_only NEVER weakens the non-bypassable floor.
        return shell_confirm_decision(command_str) if tool.name == "shell"

        # 8a. Out-of-workspace structured write → :ask (Claude-Code-aligned). A
        #     write/edit/multi_edit/apply_patch whose target resolves OUTSIDE
        #     every allowed root (and is neither temp scratch nor the agent home)
        #     is NO LONGER hard-refused at the tool boundary with no recourse:
        #     it prompts, and on approval the ToolExecutor widens the workspace
        #     to include the target's directory (Workspace.add), matching Claude
        #     Code's "writes are confined to the project; an out-of-scope write
        #     requests explicit permission" boundary. This MUST precede the 8b/8c
        #     auto-allow (which would otherwise let the write through to the
        #     tool's own guard and its dead-end refusal).
        #
        #     Below yolo (step 3) so a --yolo operator is never prompted — the
        #     ToolExecutor still widens on the yolo path so the write lands. When
        #     headless the :ask becomes the #260 fail-closed block, so an
        #     out-of-workspace write can't be silently auto-approved without a
        #     human. workspace_strict=false (no jail) ⇒ widen_target_for is nil ⇒
        #     no prompt. An explicit permissions:allow rule (step 5) already
        #     won above, so a user who pre-authorised the path isn't re-asked.
        if outside_workspace_write?(tool, arguments)
          @last_ask_reason = :outside_workspace
          return :ask
        end

        # 8b. Structured in-workspace edit symmetry (#427). Under dangerous_only,
        #    a safe `shell sed -i …` / `echo > file` runs UNPROMPTED (step 7-8),
        #    but the structured edit/write/multi_edit/apply_patch tools are
        #    :medium and would fall through to step 9 -> :ask, which fails closed
        #    headless. That asymmetry pushes automation AWAY from the clean,
        #    read-tracked, diff-producing structured tools and TOWARD raw shell
        #    mutation — worse for safety/observability and the inverse of the
        #    industry norm (Hermes runs structured in-workspace edits unprompted
        #    with file_safety.is_write_denied as the boundary; Claude Code
        #    acceptEdits, Codex auto-edit and aider all treat in-workspace edits
        #    as LOWER friction than shell). So under dangerous_only these
        #    structured edits are non-prompting too — SYMMETRIC with safe shell.
        #    This NEVER widens reach: the always-on #413 write-denylist (refuses
        #    .env/.ssh/.aws/etc even inside the workspace) and the workspace
        #    sandbox both run inside the tool's #call regardless of approval, and
        #    the hardline floor (step 1), permissions:deny (step 2) and
        #    skill-create gate (step 6c) all already ran above. confirm_all
        #    (non-default) still routes them through step 9 -> :ask unchanged.
        #
        # 8c. Code-execution tool symmetry. Under dangerous_only, arbitrary safe
        #    `shell` runs unprompted (step 7-8), yet the dedicated `ruby` tool
        #    is :medium and would fall through to step 9 -> :ask — an INVERSION:
        #    a dedicated eval tool gated HARDER than the raw shell it would
        #    otherwise be driven through. The field norm (Claude Code auto-mode,
        #    Codex full-auto, aider) auto-runs code without prompting. So under
        #    dangerous_only it is non-prompting too, aligned AT MOST to the
        #    safe-shell tier (see CODE_EXEC_TOOLS).
        #    Deny-class checks (hardline step 1, permissions:deny step 2, doom
        #    step 4) all ran first; confirm_all (non-default) still routes them
        #    through step 9 -> :ask unchanged.
        return :allow if @confirm_policy == :dangerous_only && dangerous_only_auto_allowed?(tool)

        # 9. Fall back to mode-based decision
        mode_based_decision(tool)
      end

      # True when a command matches a recoverable-but-risky DangerousPattern
      # (distinct from the hardline floor). Computed signal for the structured
      # ask context and for S4's dangerous_only confirm policy; #decide does
      # not yet branch on it (see step 7). Mirrors detect_dangerous_command.
      def dangerous?(command)
        DangerousPatterns.dangerous?(command)
      end

      # Returns true if a specific command is pre-approved by the config
      # allowlist. An empty allowlist pre-approves NOTHING.
      def command_pre_approved?(command)
        CommandAllowlist.new(config: @config).allowed?(command)
      end

      # True when this is a WRITE action of the skill tool (action: "create").
      # The skill tool is :low (so read_only keeps load/list/show), but its
      # WRITE actions (create/edit/patch/write_file/delete) author, mutate, or
      # remove a SKILL.md and must be approval-gated (#405). delete is the
      # in-process removal path (the jailed shell can't touch ~/.rubino/skills),
      # so it MUST be gated here too — otherwise a destructive removal would slip
      # through unprompted. The background review fork bypasses this via
      # Rubino.review_toolset (trusted sandboxed write); a foreground agent still
      # asks.
      def skill_write?(tool, arguments)
        return false unless tool.name == "skill"

        args = arguments || {}
        %w[create edit patch write_file delete].include?(args[:action].to_s)
      end

      # True when this is a shell call requesting the out-of-jail escape hatch
      # (disable_sandbox:true) AND the operator hasn't disabled it. The gate
      # mirrors the shell tool's own #escalate resolution so the policy and the
      # tool agree on when the flag is live: if allow_escalation is off the tool
      # ignores the flag and runs confined, so the policy must NOT prompt for it.
      def escalated_shell?(tool, arguments)
        return false unless tool.name == "shell"

        args = arguments || {}
        raw = args[:disable_sandbox]
        (raw == true || raw.to_s == "true") && Sandbox.escalation_allowed?
      end

      # The confirm_policy shell gate (steps 7-8), extracted so #decide stays
      # under the complexity limit. confirm_all → always :ask; dangerous_only →
      # :ask for a DangerousPattern OR a dangerous WRITE/EXEC flag-form, else
      # :allow.
      #
      # The flag-form screen (#dangerous_flag_form_present?) is the NARROW
      # companion to DangerousPatterns: under the shipped dangerous_only default,
      # patterns alone let genuinely dangerous flag-forms (`git -c alias.x=!cmd`,
      # `python3 -c '…'`, `sed -i`, `find -delete`, `tee FILE`) auto-run
      # unprompted (arbitrary write/RCE), while ordinary script/filter
      # invocations (`python test.py`, `sed 's/a/b/'`) must keep running without
      # a prompt for an acceptable coding-agent UX.
      def shell_confirm_decision(command_str)
        return :ask unless @confirm_policy == :dangerous_only

        dangerous?(command_str) || dangerous_flag_form_present?(command_str) ? :ask : :allow
      end

      # True when ANY chain segment of the command is a flag-form that still
      # warrants a prompt. Reuses the same quote-aware chain split as the
      # read-only auto-allow so `echo hi && sort -o /tmp/x f` is screened
      # per-segment. Fails SAFE: a segment that does not parse (split returns
      # nil, or Shellwords raises) is treated as dangerous.
      #
      # CONDITIONAL on the OS write-jail PROVING enforcement (slice 2 Part C):
      # the jail confines arbitrary WRITES, so when it is ENFORCING the pure-write
      # flag-forms (`sort -o`, `sed -i`, `git --output`, `find -delete`, `tar`
      # write/extract, …) no longer need a prompt — only the EXEC/network/system
      # forms that run arbitrary code (`python -c`, `bash -c`, `git -c`/push,
      # `perl -e`, …) do. When the jail is DEGRADED/off OR present-but-not-
      # enforcing (helper fails open) the allowlist is the ONLY guard, so the
      # broader WRITE+EXEC screen (#dangerous_flag_form?) stays in force exactly
      # as before. `DangerousPatterns.dangerous?` + the hardline floor are
      # checked separately and ALWAYS prompt/deny regardless of this gate.
      def dangerous_flag_form_present?(command_str)
        segments = ReadonlyCommands.split_segments(command_str.to_s)
        return true if segments.nil?

        # Gate on PROVEN enforcement, not mere presence: a helper that fails
        # open (kernel without Landlock) reports active? but does NOT confine,
        # so relaxing on active? would auto-run unconfined writes. enforcing?
        # runs the launcher once and only returns true when a write outside the
        # jail is actually denied. Present-but-not-enforcing ⇒ broad screen.
        enforcing = Sandbox.enforcing?
        segments.any? do |segment|
          tokens = Shellwords.split(segment)
          enforcing ? ReadonlyCommands.exec_flag_form?(tokens) : ReadonlyCommands.dangerous_flag_form?(tokens)
        rescue ArgumentError
          true
        end
      end

      # True when this is a structured read (read/grep/glob) whose target
      # resolves under the agent home (~/.rubino). config.yml, memories,
      # session data — reading any of it requires explicit approval.
      # Skill tool `load` is NOT gated (not in AGENT_HOME_READ_TOOLS).
      def agent_home_read?(tool, arguments)
        return false unless AGENT_HOME_READ_TOOLS.include?(tool.name)

        raw = self.class.command_string(tool, arguments)
        return false if raw.to_s.empty?

        SecretPath.under_agent_home?(resolve_workspace_path(raw))
      end
      # True when this call WRITES a secret/credential path and so must be
      # approval-gated. For write/edit/multi_edit the single target is resolved
      # from file_path; for apply_patch every target file in the patch is
      # checked, because one call can touch many files. Resolution is relative
      # to the workspace primary root so a relative `.env` resolves to the same
      # file the tool will open. (Reads are NOT gated — see #decide step 5b.)
      def secret_file_access?(tool, arguments)
        return false unless SECRET_GATED_WRITE_TOOLS.include?(tool.name)

        secret_targets(tool, arguments).any? { |p| SecretPath.secret?(p) }
      end

      # True when this structured write touches at least one path outside every
      # allowed root — the trigger for the Claude-Code-aligned widen prompt
      # (#decide step 8a). Non-structured tools and fully in-workspace writes
      # return false.
      def outside_workspace_write?(tool, arguments)
        return false unless STRUCTURED_EDIT_TOOLS.include?(tool.name)

        workspace_widen_dirs(tool, arguments).any?
      end

      # The directories that must be added to the workspace for this write to
      # land — one per target that resolves outside every allowed root, deduped;
      # empty for an in-workspace write. ToolExecutor adds them once the call is
      # cleared to run (after approval, or under yolo). Reuses #secret_targets so
      # the SAME per-tool target resolution the secret gate uses (write/edit/
      # multi_edit → file_path; apply_patch → every patched file) drives the
      # widen, and Tools::Base.boundary#widen_target_for applies the one shared
      # writability rule (strict-off / temp-scratch / agent-home all yield nil).
      def workspace_widen_dirs(tool, arguments)
        return [] unless STRUCTURED_EDIT_TOOLS.include?(tool.name)

        secret_targets(tool, arguments).filter_map { |t| Tools::Base.boundary.widen_target_for(t) }.uniq
      end

      # The absolute path(s) a write tool will touch. apply_patch yields one per
      # hunk target; every other gated tool yields its single file_path.
      def secret_targets(tool, arguments)
        args = arguments || {}
        if tool.name == "apply_patch"
          base = args[:base_path].to_s
          base = Tools::Base.workspace_root if base.empty?
          return patch_target_paths(args[:patch], base)
        end

        raw = self.class.command_string(tool, arguments)
        return [] if raw.to_s.empty?

        [resolve_workspace_path(raw)]
      end

      # Extracts every destination file from a unified diff (`+++ b/<file>`, and
      # `--- a/<file>` so a delete of a secret is gated too), absolutised against
      # base_path. A `/dev/null` side carries no file and is skipped.
      def patch_target_paths(patch, base_path)
        return [] if patch.nil?

        patch.to_s.each_line.filter_map do |line|
          m = line.match(%r{^[-+]{3} [ab]/(.+)\s*$})
          next if m.nil?

          File.expand_path(m[1].strip, base_path)
        end.uniq
      end

      # Anchors a relative path at the workspace primary root (matching
      # Tools::Base#expand_workspace_path) so the gate sees the same target the
      # tool will. Absolute/~ paths pass through.
      def resolve_workspace_path(path)
        str = path.to_s
        return File.expand_path(str) if str.start_with?(File::SEPARATOR, "~")

        File.expand_path(str, Tools::Base.workspace_root)
      end

      # True when the shell command is provably read-only and the
      # approvals.auto_allow_readonly gate (default ON) is open. Shell-only:
      # for every other tool the "command" is a path or argument fragment.
      def readonly_auto_allowed?(tool, command)
        return false unless tool.name == "shell"
        return false unless @config.auto_allow_readonly?

        ReadonlyCommands.auto_allowed?(command, extra: @config.approvals_readonly_commands)
      end

      # Builds the string representation of a tool call used both for
      # pattern-rule matching here and for the UI's session-approval scope
      # in ToolExecutor. One builder so the granularity stays identical:
      # approving `shell ls` never auto-approves `shell rm -rf /`.
      def self.command_string(tool, arguments)
        args = (arguments || {}).transform_keys(&:to_sym)
        case tool.name
        when "shell"
          args[:command].to_s
        when "read", "write", "edit", "multi_edit", "attach_file"
          args[:file_path].to_s
        when "grep", "glob"
          # The SEARCH ROOT (a dir or a file) is what the secret gate resolves —
          # `pattern` is the regex/glob, not a path. (Default "." like the tools.)
          (args[:path] || ".").to_s
        when "shell_output", "shell_kill", "shell_input"
          args[:run_id].to_s
        when "skill"
          # "<action> <name>" so the approval scope distinguishes a create from
          # a load and one skill name from another (granularity parity, #405).
          action = args[:action] || "load"
          name   = args[:name]
          [action, name].join(" ").strip
        else
          args.values.first.to_s
        end
      end

      # Resets doom loop detector (call on new user input)
      def reset_turn!
        @doom_detector.reset!
      end

      private

      # Tools auto-allowed under dangerous_only by the symmetry steps 8b/8c:
      # in-workspace structured edits (write-denylist + sandbox enforce inside
      # #call) and the dedicated code-exec tools, both aligned with — never
      # harder than — safe `shell`. confirm_all still routes these to :ask.
      def dangerous_only_auto_allowed?(tool)
        STRUCTURED_EDIT_TOOLS.include?(tool.name) || CODE_EXEC_TOOLS.include?(tool.name)
      end

      # Records the tool call in the doom detector and returns true ONLY when it
      # tripped AND the guard is in hard_stop mode (=> block). In the default
      # warn mode a trip sets @doom_loop_warning and returns false, so the call
      # proceeds through the normal decision path (#414).
      def doom_loop_blocks?(tool, arguments)
        return false unless @doom_detector.record(tool_name: tool.name, arguments: arguments)

        if @doom_detector.hard_stop?
          true
        else
          @doom_loop_warning = true
          false
        end
      end

      # Records WHY this deny fired before returning it (see #last_deny_reason).
      def deny_with(reason)
        @last_deny_reason = reason
        :deny
      end

      def mode_based_decision(tool)
        case @mode
        # config approvals.mode: "skip" is NOT a headless yolo (#260). It stays
        # permissive for non-risky tools (reads), but a risky tool (write/edit/
        # shell) routes to :ask so the headless fail-closed floor can block it
        # when there is no interactive session — only runtime --yolo (step 3)
        # may auto-run those headless. Interactive sessions still get a prompt.
        when "skip"
          tool.risky? ? :ask : :allow
        when "auto"
          tool.risk_level == :high ? :ask : :allow
        when "manual"
          tool.risky? ? :ask : :allow
        else
          tool.risky? ? :ask : :allow
        end
      end

      def load_permission_rules(agent_overrides)
        base_rules = @config.dig("permissions") || {}

        if agent_overrides.is_a?(Hash)
          base_rules.merge(agent_overrides)
        else
          base_rules
        end
      end
    end
  end
end
