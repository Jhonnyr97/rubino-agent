# frozen_string_literal: true

module Rubino
  module Security
    # Regex-based secret redaction for tool output — a 1:1 port of Hermes'
    # `agent/redact.py` (`redact_sensitive_text`). Masks API keys, tokens,
    # and credentials before they reach the model, the transcript, the aux
    # model, or logs.
    #
    # Applied at the same seams Hermes redacts: structured `read` content,
    # `grep` match content (both with code_file:true to skip the ENV/JSON
    # assignment patterns that false-positive on source), `shell`/background
    # shell output (full patterns — `cat .env` / `printenv` leak keys), and
    # converted-document content from `read_attachment` before it enters context.
    #
    # Short tokens (< 18 chars) are fully masked; longer ones preserve the
    # first 6 and last 4 characters for debuggability — matching Hermes'
    # `_mask_token`.
    #
    # ON by default (secure default, Hermes #17691). Opt out with
    # `security.redact_secrets: false` in config.yml (or the
    # RUBINO_REDACT_SECRETS=false env var). NOT a security boundary — the
    # shell runs as the same OS user; this is defense-in-depth that keeps
    # plaintext credentials out of context, the transcript, and the aux egress.
    module Redactor
      module_function

      # Explicit marker for a FULLY-masked secret value. Hermes' `redact.py`
      # emits a bare `***` here, which is indistinguishable from literal
      # placeholder content (a `***` in a config sample, an empty-looking value)
      # — it once made the agent read a redacted `.env` as "empty/placeholder".
      # Following the labelled-marker convention of log scrubbers (Datadog et
      # al.), a full-mask is tagged so a redacted value is never mistakable for
      # absent/placeholder content. Display-only (no parser depends on it). The
      # PARTIAL head…tail form (`sk-pro…7890`) is unchanged; only the full-mask
      # placeholder uses this marker.
      FULL_MASK = "‹redacted by rubino›"

      # Known API-key prefixes — match the prefix + contiguous token chars.
      # Ported verbatim from Hermes `_PREFIX_PATTERNS`.
      PREFIX_PATTERNS = [
        "sk-[A-Za-z0-9_-]{10,}",           # OpenAI / OpenRouter / Anthropic (sk-ant-*)
        "ghp_[A-Za-z0-9]{10,}",            # GitHub PAT (classic)
        "github_pat_[A-Za-z0-9_]{10,}",    # GitHub PAT (fine-grained)
        "gho_[A-Za-z0-9]{10,}",            # GitHub OAuth access token
        "ghu_[A-Za-z0-9]{10,}",            # GitHub user-to-server token
        "ghs_[A-Za-z0-9]{10,}",            # GitHub server-to-server token
        "ghr_[A-Za-z0-9]{10,}",            # GitHub refresh token
        "xox[baprs]-[A-Za-z0-9-]{10,}",    # Slack tokens
        "AIza[A-Za-z0-9_-]{30,}",          # Google API keys
        "pplx-[A-Za-z0-9]{10,}",           # Perplexity
        "fal_[A-Za-z0-9_-]{10,}",          # Fal.ai
        "fc-[A-Za-z0-9]{10,}",             # Firecrawl
        "bb_live_[A-Za-z0-9_-]{10,}",      # BrowserBase
        "gAAAA[A-Za-z0-9_=-]{20,}",        # Codex encrypted tokens
        "AKIA[A-Z0-9]{16}",                # AWS Access Key ID
        "sk_live_[A-Za-z0-9]{10,}",        # Stripe secret key (live)
        "sk_test_[A-Za-z0-9]{10,}",        # Stripe secret key (test)
        "rk_live_[A-Za-z0-9]{10,}",        # Stripe restricted key
        'SG\.[A-Za-z0-9_-]{10,}',          # SendGrid API key
        "hf_[A-Za-z0-9]{10,}",             # HuggingFace token
        "r8_[A-Za-z0-9]{10,}",             # Replicate API token
        "npm_[A-Za-z0-9]{10,}",            # npm access token
        "pypi-[A-Za-z0-9_-]{10,}",         # PyPI API token
        "dop_v1_[A-Za-z0-9]{10,}",         # DigitalOcean PAT
        "doo_v1_[A-Za-z0-9]{10,}",         # DigitalOcean OAuth
        "am_[A-Za-z0-9_-]{10,}",           # AgentMail API key
        "sk_[A-Za-z0-9_]{10,}",            # ElevenLabs TTS key (sk_ underscore)
        "tvly-[A-Za-z0-9]{10,}",           # Tavily search API key
        "exa_[A-Za-z0-9]{10,}",            # Exa search API key
        "gsk_[A-Za-z0-9]{10,}",            # Groq Cloud API key
        "syt_[A-Za-z0-9]{10,}",            # Matrix access token
        "retaindb_[A-Za-z0-9]{10,}",       # RetainDB API key
        "hsk-[A-Za-z0-9]{10,}",            # Hindsight API key
        "mem0_[A-Za-z0-9]{10,}",           # Mem0 Platform API key
        "brv_[A-Za-z0-9]{10,}",            # ByteRover API key
        "xai-[A-Za-z0-9]{30,}"             # xAI (Grok) API key
      ].freeze

      PREFIX_RE = /(?<![A-Za-z0-9_-])(#{PREFIX_PATTERNS.join("|")})(?![A-Za-z0-9_-])/

      # ENV assignment: KEY=value where KEY contains a secret-like name.
      # The secret word must be a WHOLE underscore-delimited component of the
      # identifier, not an arbitrary substring (#67): the old
      # `[A-Z0-9_]{0,50}AUTH[A-Z0-9_]{0,50}` matched `AUTHORS` (AUTH + ORS) and
      # mangled a plain `AUTHORS = {...}` dict into `‹redacted by rubino›`.
      # Anchor each side of the secret word to a string edge or an underscore so
      # API_KEY / OPENAI_API_KEY / GITHUB_TOKEN / AUTH_TOKEN / DB_PASSWORD still
      # match while AUTHORS / TOKENIZE / SECRETARY do not.
      SECRET_ENV_NAMES = "(?:API_?KEY|TOKEN|SECRET|PASSWORD|PASSWD|CREDENTIAL|AUTH)"
      ENV_ASSIGN_RE = /
        (
          (?:[A-Z0-9_]{0,49}_)?    # optional leading component(s), `_`-terminated
          #{SECRET_ENV_NAMES}
          (?:_[A-Z0-9_]{0,49})?    # optional trailing component(s), `_`-led
        )
        \s*=\s*(['"]?)(\S+)\2
      /x

      # JSON field: "apiKey": "value", "token": "value", etc.
      JSON_KEY_NAMES = "(?:api_?[Kk]ey|token|secret|password|access_token|" \
                       "refresh_token|auth_token|bearer|secret_value|" \
                       "raw_secret|secret_input|key_material)"
      JSON_FIELD_RE = /("#{JSON_KEY_NAMES}")\s*:\s*"([^"]+)"/i

      # Authorization headers.
      AUTH_HEADER_RE = /(Authorization:\s*Bearer\s+)(\S+)/i

      # Telegram bot tokens: `bot<id>:<token>` or `<id>:<token>`. The bot id is
      # 8-10 digits and the token is EXACTLY 35 chars — the canonical Telegram
      # format. The original `\d{8,}:[...]{30,}` was too broad: any 8+ digit
      # number colon-joined to a 30+ char run (a unix-nanos timestamp, a long
      # numeric id, a 32-char session value) false-matched and got FULL_MASK'd,
      # so a plain `python3 -c` printing a non-secret dict had output replaced
      # with `‹redacted by rubino›`. Pinning the id to 8-10 digits (with a
      # word-boundary so a longer number can't lend its tail) and the token to
      # the exact 35-char length keeps every real bot token caught while the
      # arbitrary timestamp:value shapes no longer match.
      TELEGRAM_RE = /(?<![A-Za-z0-9_-])(bot)?(\d{8,10}):([-A-Za-z0-9_]{35})(?![A-Za-z0-9_-])/

      # Private key blocks.
      PRIVATE_KEY_RE = /-----BEGIN[A-Z ]*PRIVATE KEY-----[\s\S]*?-----END[A-Z ]*PRIVATE KEY-----/

      # Database connection strings: protocol://user:PASSWORD@host.
      DB_CONNSTR_RE = %r{((?:postgres(?:ql)?|mysql|mongodb(?:\+srv)?|redis|amqp)://[^:]+:)([^@]+)(@)}i

      # JWT tokens: header.payload[.signature] — always start with "eyJ".
      JWT_RE = /eyJ[A-Za-z0-9_-]{10,}(?:\.[A-Za-z0-9_=-]{4,}){0,2}/

      # Discord user/role mentions.
      DISCORD_MENTION_RE = /<@!?(\d{17,20})>/

      # E.164 phone numbers.
      SIGNAL_PHONE_RE = /(\+[1-9]\d{6,14})(?![A-Za-z0-9])/

      # Form-urlencoded body: only triggers on a pure k=v&k=v body.
      FORM_BODY_RE = /\A[A-Za-z_][A-Za-z0-9_.-]*=[^&\s]*(?:&[A-Za-z_][A-Za-z0-9_.-]*=[^&\s]*)+\z/

      SENSITIVE_QUERY_PARAMS = %w[
        access_token refresh_token id_token token api_key apikey client_secret
        password auth jwt session secret key code signature x-amz-signature
      ].to_set.freeze

      # True when secret redaction is enabled. ON by default; opt out with
      # `security.redact_secrets: false` or RUBINO_REDACT_SECRETS=false.
      def enabled?
        env = ENV.fetch("RUBINO_REDACT_SECRETS", nil)
        return %w[1 true yes on].include?(env.downcase) unless env.nil? || env.empty?

        Rubino.configuration.dig("security", "redact_secrets") != false
      rescue StandardError
        true
      end

      # Mask a secret token, preserving 6 leading / 4 trailing chars; values
      # shorter than 18 chars are fully masked. Mirrors Hermes `_mask_token`.
      def mask_token(token)
        return FULL_MASK if token.nil? || token.empty?
        return FULL_MASK if token.length < 18

        "#{token[0, 6]}...#{token[-4, 4]}"
      end

      # Apply all redaction patterns to +text+. Safe on any string — non-
      # matching text passes through unchanged. Set +force:+ for seams that
      # must never return raw secrets regardless of the opt-out. Set
      # +code_file:+ to skip the ENV/JSON assignment patterns (source code
      # false-positives like MAX_TOKENS=*** constants).
      def redact_sensitive_text(text, force: false, code_file: false)
        return text if text.nil?

        text = text.to_s unless text.is_a?(String)
        return text if text.empty?
        return text unless force || enabled?

        # Known prefixes (sk-, ghp_, …).
        text = text.gsub(PREFIX_RE) { mask_token(::Regexp.last_match(1)) }
        # ENV/JSON assignments — skipped for source code (false positives).
        text = redact_assignments(text) unless code_file
        # Remaining shape patterns (auth header, JWT, DB, …), each cheaply
        # substring-gated, applied in Hermes' exact order.
        redact_misc_patterns(text)
      end

      # ENV-assignment + JSON-field masking — the two patterns Hermes skips for
      # source files (`code_file:true`). KEY/quotes preserved, value masked.
      def redact_assignments(text)
        if text.include?("=")
          text = text.gsub(ENV_ASSIGN_RE) do
            m = ::Regexp.last_match
            "#{m[1]}=#{m[2]}#{mask_token(m[3])}#{m[2]}"
          end
        end
        return text unless text.include?(":") && text.include?('"')

        text.gsub(JSON_FIELD_RE) do
          m = ::Regexp.last_match
          %(#{m[1]}: "#{mask_token(m[2])}")
        end
      end

      # The remaining shape patterns, applied in Hermes' order. Web-URL
      # query/userinfo redaction is intentionally OFF, matching Hermes —
      # legitimate magic-link / OAuth-callback / pre-signed URLs pass opaque
      # tokens through query strings. Known credential shapes inside URLs are
      # still caught by PREFIX_RE / JWT_RE; DB passwords by DB_CONNSTR_RE.
      def redact_misc_patterns(text)
        # Prefix-less AWS secret-access-key (40-char base64, no prefix of its
        # own) — only masked when it sits next to an `aws_secret_access_key`
        # cue, so a bare 40-char base64/hex blob in normal output is NOT touched
        # (preserves the #67 no-over-redaction contract). Precise/context-gated,
        # safe on both prose and source.
        if text =~ /secret/i && text =~ /key/i
          text = text.gsub(SecretDetector::AWS_SECRET_KEY_RE) do
            m = ::Regexp.last_match
            m[0].sub(m[2], mask_token(m[2]))
          end
        end
        if text =~ /uthorization/i
          text = text.gsub(AUTH_HEADER_RE) { "#{::Regexp.last_match(1)}#{mask_token(::Regexp.last_match(2))}" }
        end
        if text.include?(":")
          text = text.gsub(TELEGRAM_RE) { "#{::Regexp.last_match(1)}#{::Regexp.last_match(2)}:#{FULL_MASK}" }
        end
        text = text.gsub(PRIVATE_KEY_RE, "[REDACTED PRIVATE KEY]") if text.include?("BEGIN") && text.include?("-----")
        if text.include?("://")
          text = text.gsub(DB_CONNSTR_RE) { "#{::Regexp.last_match(1)}#{FULL_MASK}#{::Regexp.last_match(3)}" }
        end
        text = text.gsub(JWT_RE) { mask_token(::Regexp.last_match(0)) } if text.include?("eyJ")
        text = redact_form_body(text) if text.include?("&") && text.include?("=")
        if text.include?("<@")
          text = text.gsub(DISCORD_MENTION_RE) { |m| "<@#{"!" if m.include?("!")}***>" }
        end
        text = redact_phones(text) if text.include?("+")
        text
      end

      # E.164 phone masking (Signal / WhatsApp).
      def redact_phones(text)
        text.gsub(SIGNAL_PHONE_RE) do
          phone = ::Regexp.last_match(1)
          if phone.length <= 8
            "#{phone[0, 2]}****#{phone[-2, 2]}"
          else
            "#{phone[0, 4]}****#{phone[-4, 4]}"
          end
        end
      end

      # Redact sensitive values in a URL query string (k=v&k=v).
      def redact_query_string(query)
        return query if query.nil? || query.empty?

        query.split("&").map do |pair|
          next pair unless pair.include?("=")

          key, _, _value = pair.partition("=")
          SENSITIVE_QUERY_PARAMS.include?(key.downcase) ? "#{key}=#{FULL_MASK}" : pair
        end.join("&")
      end

      # Redact a pure form-urlencoded body — only when the WHOLE input looks
      # like k=v&k=v with no newlines (conservative, matches Hermes).
      def redact_form_body(text)
        return text if text.nil? || text.empty? || text.include?("\n") || !text.include?("&")
        return text unless FORM_BODY_RE.match?(text.strip)

        redact_query_string(text.strip)
      end
    end
  end
end
