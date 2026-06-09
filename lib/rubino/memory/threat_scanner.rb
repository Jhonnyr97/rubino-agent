# frozen_string_literal: true

module Rubino
  module Memory
    # Scans content destined for the memories table for adversarial patterns.
    #
    # Memory is a long-lived, cross-session channel that gets *spliced into
    # every future system prompt*, so a single tainted write can persistently
    # bias the agent across runs. We inspect every write at the boundary and
    # refuse anything that smells like a known injection / exfiltration
    # vector. We deliberately err on the side of false-positives — the agent
    # can rephrase, but a planted directive in memory has no antidote.
    #
    # `.scan(content)` returns nil when safe, otherwise a short string
    # describing the threat (used as both error_code label and audit log
    # payload).
    class ThreatScanner
      # Prompt-injection markers. These are the cliches that show up in
      # documented jailbreak attempts; any one match is enough to refuse —
      # legitimate user-profile content has no reason to embed them.
      PROMPT_INJECTION_PATTERNS = [
        /ignore (?:all |the )?previous/i,
        /disregard (?:all |the )?(?:above|previous)/i,
        /you are now/i,
        /new instructions:/i,
        /^\s*system\s*:/i,
        /^\s*assistant\s*:/i,
        /<\|im_start\|>/i,
        /<\|im_end\|>/i,
        /\[INST\]/i
      ].freeze

      # Credentials embedded in a URL — classic data-exfil channel
      # (scheme://user:pass@host).
      URL_CREDENTIAL_PATTERN = %r{\b[a-z][a-z0-9+\-.]*://[^/\s:@]+:[^/\s@]+@}i

      # Contiguous base64 of 200+ chars. Reasonable prose never has this;
      # encoded payloads (binaries, encrypted blobs) do.
      BASE64_BLOB_PATTERN = %r{[A-Za-z0-9+/]{200,}={0,2}}

      # curl/wget piped to a shell — remote code execution recipe.
      PIPE_TO_SHELL_PATTERN = /\b(?:curl|wget)\b[^\n]*\|\s*(?:sudo\s+)?(?:bash|sh|zsh)\b/i

      # Zero-width characters and BIDI override / isolate codepoints. Used
      # to hide instructions or swap visible text direction — see the
      # "Trojan Source" class of attacks (CVE-2021-42574).
      INVISIBLE_UNICODE_PATTERN = /[​‌‍﻿‮⁦-⁩]/

      class << self
        # Returns nil when the content is safe, otherwise a short string
        # naming the detected threat class (e.g. "prompt_injection").
        def scan(content)
          return nil if content.nil? || content.empty?

          text = content.to_s

          return "prompt_injection" if PROMPT_INJECTION_PATTERNS.any? { |p| text.match?(p) }
          return "exfiltration_url_credentials" if text.match?(URL_CREDENTIAL_PATTERN)
          return "exfiltration_pipe_to_shell" if text.match?(PIPE_TO_SHELL_PATTERN)
          return "exfiltration_base64_blob" if text.match?(BASE64_BLOB_PATTERN)
          return "invisible_unicode" if text.match?(INVISIBLE_UNICODE_PATTERN)

          nil
        end
      end
    end
  end
end
