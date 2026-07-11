# frozen_string_literal: true

module Rubino
  module Security
    # Scans externally-loaded instruction content (project context files,
    # SKILL.md bodies, agent .md system prompts, command .md templates) for
    # prompt-injection / promptware / exfiltration patterns BEFORE the content
    # reaches the system prompt or a user message.
    #
    # Mirrors Hermes's two-layer defence:
    #   1. threat_patterns.py — the shared pattern set (regexes + invisible
    #      unicode characters), and
    #   2. prompt_builder.py::_scan_context_content — the BLOCK-on-match
    #      behaviour for context files.
    #
    # On a match the content is replaced with a BLOCKED placeholder (so it
    # never reaches the model) and a structured warning is logged with the
    # source path + matched category. Clean content passes through unchanged.
    #
    # Design note: this is a module with a single class method, not an
    # instantiable object like Redactor. The four wiring points are method
    # calls that need a yes/no + placeholder — there is no per-scan state.
    # If any future caller needs per-scan config, a thin object can wrap
    # ContentScanner.scan without changing the API.
    module ContentScanner
      # Invisible / bidirectional unicode characters used in injection attacks.
      # Aligned with Hermes threat_patterns.py INVISIBLE_CHARS.
      INVISIBLE_CHARS = [
        "\u200b", # zero-width space
        "\u200c", # zero-width non-joiner
        "\u200d", # zero-width joiner
        "\u2060", # word joiner
        "\u2062", # invisible times
        "\u2063", # invisible separator
        "\u2064", # invisible plus
        "\ufeff", # zero-width no-break space (BOM)
        "\u202a", # left-to-right embedding
        "\u202b", # right-to-left embedding
        "\u202c", # pop directional formatting
        "\u202d", # left-to-right override
        "\u202e", # right-to-left override
        "\u2066", # left-to-right isolate
        "\u2067", # right-to-left isolate
        "\u2068", # first strong isolate
        "\u2069"  # pop directional isolate
      ].to_set.freeze

      # Each entry: [regex, pattern_id, scope]
      # scope ∈ {"all", "context"}
      # "all" patterns apply everywhere; "context" patterns add promptware /
      # C2 / role-hijack detection.
      #
      # Copied faithfully from Hermes threat_patterns.py _PATTERNS.
      # The "strict" scope (SSH backdoor, persistence, exfil-URL) is NOT
      # included — it is only used by memory writes and skill installs in
      # Hermes, which have user-mediated confirmation. Context files from a
      # cloned repo (security research, infra docs) would false-positive.
      # rubocop:disable Layout/LineLength
      BYPASS_RESTRICTIONS_RE =
        /act\s+as\s+(?:if|though)\s+(?:\w+\s+)*you\s+(?:\w+\s+)*(?:have\s+no|don't\s+have)\s+(?:\w+\s+)*(?:restrictions|limits|rules)/i
      DISREGARD_RULES_RE =
        /disregard\s+(?:\w+\s+)*(?:your|all|any)\s+(?:\w+\s+)*(?:instructions|rules|guidelines)/i
      REMOVE_FILTERS_RE =
        /(?:respond|answer|reply)\s+without\s+(?:\w+\s+)*(?:restrictions|limitations|filters|safety)/i
      ANTI_FORENSIC_DISK_RE =
        /never\s+(?:\w+\s+)*(?:create|write)\s+(?:\w+\s+)*(?:script|file)\s+(?:\w+\s+)*disk/i
      # rubocop:enable Layout/LineLength

      PATTERNS = [
        # ── Classic prompt injection (applies everywhere) ────────────────
        [/\bignore\s+(?:\w+\s+)*(?:previous|all|above|prior)\s+(?:\w+\s+)*instructions/i, "prompt_injection", "all"],
        [/system\s+prompt\s+override/i, "sys_prompt_override", "all"],
        [DISREGARD_RULES_RE, "disregard_rules", "all"],
        [BYPASS_RESTRICTIONS_RE, "bypass_restrictions", "all"],
        [/<!--[^>]*(?:ignore|override|system|secret|hidden)[^>]*-->/i, "html_comment_injection", "all"],
        [/<\s*div\s+style\s*=\s*["'][\s\S]*?display\s*:\s*none/i, "hidden_div", "all"],
        [/translate\s+.*\s+into\s+.*\s+(?:execute|run|eval)/i, "translate_execute", "all"],
        [/do\s+not\s+(?:\w+\s+)*tell\s+(?:\w+\s+)*the\s+user/i, "deception_hide", "all"],

        # ── Role-play / identity hijack (context scope) ──────────────────
        [/you\s+are\s+(?:\w+\s+)*now\s+(?:a|an|the)\s+/i, "role_hijack", "context"],
        [/pretend\s+(?:\w+\s+)*(?:you\s+are|to\s+be)\s+/i, "role_pretend", "context"],
        [/output\s+(?:\w+\s+)*(?:system|initial)\s+prompt/i, "leak_system_prompt", "context"],
        [REMOVE_FILTERS_RE, "remove_filters", "context"],
        [/you\s+have\s+been\s+(?:\w+\s+)*(?:updated|upgraded|patched)\s+to/i, "fake_update", "context"],
        [/\bname\s+yourself\s+\w+/i, "identity_override", "context"],

        # ── C2 / Brainworm-style promptware (context scope) ──────────────
        [/register\s+(?:as\s+)?a?\s*node/i, "c2_node_registration", "context"],
        [/(?:heartbeat|beacon|check[\s-]?in)\s+(?:to|with)\s+/i, "c2_heartbeat", "context"],
        [/pull\s+(?:down\s+)?(?:new\s+)?task(?:ing|s)?\b/i, "c2_task_pull", "context"],
        [/connect\s+to\s+the\s+network\b/i, "c2_network_connect", "context"],
        [/you\s+must\s+(?:\w+\s+){0,3}(?:register|connect|report|beacon)\b/i, "forced_action", "context"],
        [/only\s+use\s+one[\s-]?liners?\b/i, "anti_forensic_oneliner", "context"],
        [ANTI_FORENSIC_DISK_RE, "anti_forensic_disk", "context"],
        [/unset\s+\w*(?:CLAUDE|CODEX|HERMES|AGENT|OPENAI|ANTHROPIC)\w*/i, "env_var_unset_agent", "context"],

        # ── Known C2 / red-team framework names (context scope) ──────────
        [/\b(?:praxis|cobalt\s*strike|sliver|havoc|mythic|metasploit|brainworm)\b/i, "known_c2_framework", "context"],
        [/\bc2\s+(?:server|channel|infrastructure|beacon)\b/i, "c2_explicit", "context"],
        [/\bcommand\s+and\s+control\b/i, "c2_explicit_long", "context"],

        # ── Exfiltration via curl/wget/cat with secrets (applies everywhere)
        [/curl\s+[^\n]*\$\{?\w*(?:KEY|TOKEN|SECRET|PASSWORD|CREDENTIAL|API)/i, "exfil_curl", "all"],
        [/wget\s+[^\n]*\$\{?\w*(?:KEY|TOKEN|SECRET|PASSWORD|CREDENTIAL|API)/i, "exfil_wget", "all"],
        [/cat\s+[^\n]*(?:\.env|credentials|\.netrc|\.pgpass|\.npmrc|\.pypirc)/i, "read_secrets", "all"]
      ].freeze

      # Scan +content+ for injection threats at the given +scope+.
      #
      # +source+ is a human-readable label (filename, path) used in the BLOCKED
      # placeholder and the log line so a blocked file is diagnosable.
      #
      # +scope+ controls which pattern set to apply:
      #   "all"     — narrow: classic injection + exfil only (minimal FP)
      #   "context" — default: adds promptware / C2 / role-play patterns
      #
      # Returns the original content when clean, or a
      #   "[BLOCKED: #{source} contained potential prompt injection (...). Content not loaded.]"
      # placeholder when one or more patterns matched.
      def self.scan(content, source:, scope: "context")
        return content if content.nil? || content.to_s.strip.empty?

        text = content.to_s
        # Invisible unicode — single pass through the content set.
        char_set = text.chars.to_set
        invisible_hits = char_set & INVISIBLE_CHARS
        findings = invisible_hits.map do |ch|
          format("invisible_unicode_U+%04X", ch.ord)
        end

        # Threat patterns — filter by scope.
        PATTERNS.each do |regex, pid, pscope|
          next unless scope_applies?(pscope, scope)
          next unless regex.match?(text)

          findings << pid
        end

        return content if findings.empty?

        Rubino.logger&.warn(
          event: "content_scan.blocked",
          source: source,
          matched: findings.join(", ")
        )

        "[BLOCKED: #{source} contained potential prompt injection " \
          "(#{findings.join(", ")}). Content not loaded.]"
      end

      # Whether a pattern with scope +pscope+ fires at the requested +scope+.
      # "all" patterns always fire. "context" patterns fire when the caller
      # requests "context".
      def self.scope_applies?(pscope, scope)
        pscope == "all" || (pscope == "context" && scope == "context")
      end
    end
  end
end
