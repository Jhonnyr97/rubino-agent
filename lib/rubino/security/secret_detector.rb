# frozen_string_literal: true

module Rubino
  module Security
    # Shared secret/credential detection used by two seams:
    #
    #   1. Output redaction (Redactor) — the PREFIXLESS_PATTERNS below are
    #      folded into `redact_sensitive_text` so prefix-less credential SHAPES
    #      (an AWS secret-access-key near `aws_secret`, etc.) get masked in tool
    #      output. PRECISE patterns only — NO entropy sweep on tool output, which
    #      would over-redact hashes / UUIDs / base64 blobs in normal output
    #      (the #67 over-redaction class).
    #
    #   2. The memory WRITE path (ThreatScanner) — `present?(content)` is the
    #      gate. A memory save is long-lived (spliced into every future system
    #      prompt) and a false positive is cheap (a fact just isn't saved), so
    #      here we ALSO run a conservative high-entropy heuristic on top of the
    #      known shapes. A secret-bearing write is refused.
    #
    # The known-prefix shapes (sk-, ghp_, AKIA, AIza, xox*, JWT, PEM, …) are
    # reused from Redactor so there is a SINGLE source of truth for them.
    module SecretDetector
      module_function

      # Prefix-less credential SHAPES that the prefixed PREFIX_RE misses. These
      # are precise (anchored / context-gated) so they are safe to run on tool
      # OUTPUT as well as on the memory-write path.
      #
      # AWS secret access key: a 40-char base64 token has no prefix of its own,
      # so we only treat it as a secret when it appears NEAR an
      # `aws_secret_access_key` / `aws_secret` cue (assignment, JSON field, CLI
      # flag). Anchored to a non-token boundary so a longer blob can't lend a
      # 40-char window.
      AWS_SECRET_KEY_RE = %r{
        (?:aws.{0,4}secret.{0,4}(?:access.{0,4})?key|secret.{0,4}access.{0,4}key)
        ['"]?\s*[=:]\s*    # optional closing quote of the key, then = or :
        (['"]?)
        ([A-Za-z0-9/+]{40})
        \1
      }xi

      # Standalone shapes that are specific enough to flag without a context cue.
      PREFIXLESS_PATTERNS = [
        AWS_SECRET_KEY_RE
      ].freeze

      # --- high-entropy heuristic (memory-write path ONLY) ---------------------
      #
      # A conservative generic-secret detector for the write path, where a false
      # positive only costs an un-saved fact. We require ALL of:
      #   * a long contiguous token (>= MIN_ENTROPY_LEN chars),
      #   * a "rich" charset — BOTH letters-of-mixed-case AND digits (this alone
      #     excludes hex git SHAs, lowercase hex, and UUIDs, which are
      #     hex+dashes only), and
      #   * Shannon entropy >= MIN_ENTROPY_BITS bits/char.
      # The combination keeps git SHAs (40 hex, ~4.0 bits but no mixed case),
      # UUIDs (dashed hex), and ordinary words well below the bar while real
      # 40-char API secrets (mixed case + digits, ~5.2 bits/char) trip it.
      MIN_ENTROPY_LEN = 25
      MIN_ENTROPY_BITS = 4.0
      # Token = a contiguous run of base64-url chars (no separators). UUIDs and
      # dotted/dashed identifiers are split into short pieces and never reach the
      # length bar as a single token.
      TOKEN_RE = %r{[A-Za-z0-9+/_=-]{#{MIN_ENTROPY_LEN},}}

      # True when +text+ carries a credential. +entropy:+ enables the generic
      # high-entropy heuristic (memory-write path); leave it false for tool
      # output (precise shapes only).
      def present?(text, entropy: false)
        return false if text.nil?

        s = text.to_s
        return false if s.empty?

        return true if Redactor::PREFIX_RE.match?(s)
        return true if s.include?("eyJ") && Redactor::JWT_RE.match?(s)
        return true if s.include?("PRIVATE KEY") && Redactor::PRIVATE_KEY_RE.match?(s)
        return true if PREFIXLESS_PATTERNS.any? { |re| re.match?(s) }
        return true if entropy && high_entropy_secret?(s)

        false
      end

      # Scan each contiguous long token; flag if any clears both the charset and
      # the Shannon-entropy bar.
      def high_entropy_secret?(text)
        text.scan(TOKEN_RE).any? do |tok|
          rich_charset?(tok) && shannon_entropy(tok) >= MIN_ENTROPY_BITS
        end
      end

      # Rich charset = has lowercase AND uppercase letters AND a digit. Hex
      # SHAs / UUIDs (single-case hex) and all-lower / all-upper words fail this.
      def rich_charset?(tok)
        tok.match?(/[a-z]/) && tok.match?(/[A-Z]/) && tok.match?(/[0-9]/)
      end

      # Shannon entropy in bits per character.
      def shannon_entropy(str)
        len = str.length.to_f
        return 0.0 if len.zero?

        str.each_char.tally.values.sum(0.0) do |count|
          p = count / len
          -p * Math.log2(p)
        end
      end
    end
  end
end
