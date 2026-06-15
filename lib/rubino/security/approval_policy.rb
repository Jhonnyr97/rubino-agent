# frozen_string_literal: true

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

      # Why the most recent #decide returned :deny — :hardline (the
      # non-bypassable floor), :permission_rule (an explicit permissions deny
      # rule), or :doom_loop (the repeated-identical-call guard). nil when the
      # last decision wasn't a deny. ToolExecutor reads this right after
      # #decide to build a reason-specific model-facing denial message, so a
      # policy denial is never reported as "denied by user" (#143).
      attr_reader :last_deny_reason

      def initialize(config: nil, agent_overrides: nil)
        @config = config || Rubino.configuration
        @mode = @config.approvals_mode
        # Effective shell prompt policy (:confirm_all | :dangerous_only).
        # Derived from security.confirm_policy, with security.require_confirmation_for_shell
        # as a back-compat alias (see Configuration#confirm_policy). Older config
        # objects that predate the accessor fall back to :confirm_all.
        @confirm_policy =
          @config.respond_to?(:confirm_policy) ? @config.confirm_policy : :confirm_all
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
      def decide(tool, arguments: {})
        @last_deny_reason = nil
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

        # 5. Remaining explicit pattern rules (allow / ask). deny was already
        #    handled in step 2.
        return pattern_result if pattern_result

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

        # 6c. skill(action: "create") WRITES .rubino/skills/<name>/SKILL.md and
        #    must not be a silent low-risk allow (#405): the skill tool stays
        #    :low so a read_only agent keeps `skill load/list/show`, but the
        #    create action is a write and routes to :ask here — like any write.
        #    Below yolo (step 3), so a full-access --yolo agent still creates
        #    skills inline; a headless read_only subagent's :ask becomes the
        #    fail-closed block, closing the unapproved-write path. load is never
        #    gated (only the create action matches).
        return :ask if skill_create?(tool, arguments)

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
        #    confirm_all (DEFAULT, == legacy require_confirmation_for_shell:true)
        #      every such shell command -> :ask. shell is :high risk so manual
        #      mode would ask anyway; this also keeps it gated under auto mode.
        #
        #    dangerous_only (reference-faithful, == legacy alias:false)
        #      prompt ONLY when the command matches a DangerousPattern
        #      (git push --force, curl|sh, recursive rm of a non-root path,
        #      ...). Safe commands run unprompted. Mirrors approval.py:475
        #      where detect_dangerous_command is the sole prompt trigger.
        #      The hardline floor (step 1) and permissions:deny (step 2) already
        #      ran, so dangerous_only NEVER weakens the non-bypassable floor.
        if tool.name == "shell"
          case @confirm_policy
          when :dangerous_only
            return :ask if dangerous?(command_str)

            return :allow
          else # :confirm_all
            return :ask
          end
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
        return :allow if @confirm_policy == :dangerous_only && STRUCTURED_EDIT_TOOLS.include?(tool.name)

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

      # True when this is the WRITE action of the skill tool (action: "create").
      # The skill tool is :low (so read_only keeps load/list/show), but its
      # create action writes a SKILL.md and must be approval-gated (#405).
      def skill_create?(tool, arguments)
        return false unless tool.name == "skill"

        args = arguments || {}
        (args["action"] || args[:action]).to_s == "create"
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
        args = arguments || {}
        case tool.name
        when "shell"
          (args["command"] || args[:command]).to_s
        when "read", "write", "edit", "multi_edit", "attach_file"
          (args["file_path"] || args[:file_path]).to_s
        when "shell_output", "shell_kill", "shell_input"
          (args["run_id"] || args[:run_id]).to_s
        when "skill"
          # "<action> <name>" so the approval scope distinguishes a create from
          # a load and one skill name from another (granularity parity, #405).
          action = args["action"] || args[:action] || "load"
          name   = args["name"] || args[:name]
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
