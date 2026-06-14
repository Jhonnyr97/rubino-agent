# frozen_string_literal: true

module Rubino
  # OS-level execution sandbox seam.
  #
  # Three layers gate what the shell tool runs (#290):
  #
  #   1. ApprovalPolicy / allowlist  — *whether* a command runs (advisory).
  #   2. HardlineGuard               — best-effort anti-accident blocklist.
  #   3. Execution::SandboxBackend   — the real, kernel-enforced boundary.
  #
  # This module is layer 3. It owns the SINGLE decision of "what argv do we
  # actually hand to Process.spawn", so the existing shell machinery
  # (chdir:/pgroup:/out:/err:, the merged-pipe drain, timeout, cancel) is
  # untouched: the backend just rewrites the leading `["bash", ...]` argv.
  module Execution
    # Picks the backend for the current process. DEFAULT is LocalBackend
    # (byte-identical to the historical behaviour); SandboxBackend is opt-in
    # via config (execution.sandbox) and degrades back to Local when the OS
    # mechanism is unavailable — see SandboxBackend.available?.
    module Backend
      module_function

      # Resolves the active backend. Order:
      #   - runtime YOLO / :full_access  -> Local (the existing escape hatch)
      #   - execution.sandbox == true     -> Sandbox (or Local if it degrades)
      #   - otherwise                     -> Local (unchanged default)
      def current
        return LocalBackend.new unless sandbox_requested?

        SandboxBackend.new(mode: configured_mode)
      end

      # The shell argv for `command`. `writable_roots` are absolute directory
      # paths the command is allowed to write to (the workspace roots); the
      # backend may widen them with /tmp, $TMPDIR and the session temp.
      def argv(command, writable_roots: [])
        current.argv(command, writable_roots: writable_roots)
      end

      # True when the user has opted into the sandbox AND we are not in the
      # full-access escape hatch (runtime YOLO). full_access deliberately
      # maps to LocalBackend so `--yolo` keeps its "trust the model to move
      # fast" contract.
      def sandbox_requested?
        return false if full_access?

        Rubino.configuration&.dig("execution", "sandbox") == true
      end

      # The sandbox mode when enabled. Mirrors Codex, kept tiny:
      #   :read_only       — no writes anywhere.
      #   :workspace_write — writable = workspace + /tmp + $TMPDIR (default).
      #   :full_access     — LocalBackend (handled before we get here).
      def configured_mode
        raw = Rubino.configuration&.dig("execution", "mode").to_s
        sym = raw.strip.downcase.to_sym
        %i[read_only workspace_write full_access].include?(sym) ? sym : :workspace_write
      end

      # Network egress allowed inside the sandbox? Off by default.
      def network_enabled?
        Rubino.configuration&.dig("execution", "network") == true
      end

      # full_access is the runtime YOLO escape hatch (already documented as
      # "trust the model"): it bypasses the sandbox by design.
      def full_access?
        configured = Rubino.configuration&.dig("execution", "mode").to_s.strip.downcase
        configured == "full_access" || Rubino::Modes.current == Rubino::Modes::YOLO
      end
    end
  end
end
