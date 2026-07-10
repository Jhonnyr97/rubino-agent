# frozen_string_literal: true

module Rubino
  module Security
    # Plug-and-play secret redaction for tool output.
    #
    # Port of Hermes' `agent/redact.py` (`redact_sensitive_text`), converted
    # from a module_function to an instantiable, injectable interface so teams
    # can bring their own patterns or drop in a custom redactor.
    #
    # Interface (the contract — small and documented):
    #   #redact(text, profile:) -> String
    #
    #   profile ∈ :code | :shell | :attachment | :none
    #     :code       — source file (skip ENV/JSON assignment patterns)
    #     :shell      — command output (full patterns, the default)
    #     :attachment — converted document (full patterns)
    #     :none       — structured output, no redaction needed
    #
    # Usage:
    #   - Built-in:  Redactor.new(config)
    #   - Custom:    set security.redaction.class in config.yml,
    #                implement #redact(text, profile:)
    #   - Patterns:  set security.redaction.custom_patterns for additive regex
    #
    # Resolved once per process via Redactor.resolve (memoized).
    class Redactor
      # Explicit marker for a FULLY-masked secret value.
      FULL_MASK = "‹redacted by rubino›"

      # ── Patterns (class-level constants, shared with custom subclasses) ──

      PREFIX_PATTERNS = [
        "sk-[A-Za-z0-9_-]{10,}", "ghp_[A-Za-z0-9]{10,}", "github_pat_[A-Za-z0-9_]{10,}",
        "gho_[A-Za-z0-9]{10,}", "ghu_[A-Za-z0-9]{10,}", "ghs_[A-Za-z0-9]{10,}",
        "ghr_[A-Za-z0-9]{10,}", "xox[baprs]-[A-Za-z0-9-]{10,}",
        "AIza[A-Za-z0-9_-]{30,}", "pplx-[A-Za-z0-9]{10,}", "fal_[A-Za-z0-9_-]{10,}",
        "fc-[A-Za-z0-9]{10,}", "bb_live_[A-Za-z0-9_-]{10,}",
        "gAAAA[A-Za-z0-9_=-]{20,}", "AKIA[A-Z0-9]{16}",
        "sk_live_[A-Za-z0-9]{10,}", "sk_test_[A-Za-z0-9]{10,}",
        "rk_live_[A-Za-z0-9]{10,}", 'SG\.[A-Za-z0-9_-]{10,}',
        "hf_[A-Za-z0-9]{10,}", "r8_[A-Za-z0-9]{10,}", "npm_[A-Za-z0-9]{10,}",
        "pypi-[A-Za-z0-9_-]{10,}", "dop_v1_[A-Za-z0-9]{10,}",
        "doo_v1_[A-Za-z0-9]{10,}", "am_[A-Za-z0-9_-]{10,}",
        "sk_[A-Za-z0-9_]{10,}", "tvly-[A-Za-z0-9]{10,}", "exa_[A-Za-z0-9]{10,}",
        "gsk_[A-Za-z0-9]{10,}", "syt_[A-Za-z0-9]{10,}", "retaindb_[A-Za-z0-9]{10,}",
        "hsk-[A-Za-z0-9]{10,}", "mem0_[A-Za-z0-9]{10,}", "brv_[A-Za-z0-9]{10,}",
        "xai-[A-Za-z0-9]{30,}"
      ].freeze

      PREFIX_RE = /(?<![A-Za-z0-9_-])(#{PREFIX_PATTERNS.join("|")})(?![A-Za-z0-9_-])/

      SECRET_ENV_NAMES = "(?:API_?KEY|TOKEN|SECRET|PASSWORD|PASSWD|CREDENTIAL|AUTH)"
      ENV_ASSIGN_RE = /
        (
          (?:[A-Z0-9_]{0,49}_)?    # optional leading component(s), `_`-terminated
          #{SECRET_ENV_NAMES}
          (?:_[A-Z0-9_]{0,49})?    # optional trailing component(s), `_`-led
        )
        \s*=\s*(['"]?)(\S+)\2
      /x

      JSON_KEY_NAMES = "(?:api_?[Kk]ey|token|secret|password|access_token|" \
                       "refresh_token|auth_token|bearer|secret_value|" \
                       "raw_secret|secret_input|key_material)"
      JSON_FIELD_RE = /("#{JSON_KEY_NAMES}")\s*:\s*"([^"]+)"/i

      AUTH_HEADER_RE = /(Authorization:\s*Bearer\s+)(\S+)/i
      TELEGRAM_RE    = /(?<![A-Za-z0-9_-])(bot)?(\d{8,10}):([-A-Za-z0-9_]{35})(?![A-Za-z0-9_-])/
      PRIVATE_KEY_RE = /-----BEGIN[A-Z ]*PRIVATE KEY-----[\s\S]*?-----END[A-Z ]*PRIVATE KEY-----/
      DB_CONNSTR_RE  = %r{((?:postgres(?:ql)?|mysql|mongodb(?:\+srv)?|redis|amqp)://[^:]+:)([^@]+)(@)}i
      JWT_RE         = /eyJ[A-Za-z0-9_-]{10,}(?:\.[A-Za-z0-9_=-]{4,}){0,2}/
      DISCORD_MENTION_RE = /<@!?(\d{17,20})>/
      SIGNAL_PHONE_RE    = /(\+[1-9]\d{6,14})(?![A-Za-z0-9])/
      FORM_BODY_RE = /\A[A-Za-z_][A-Za-z0-9_.-]*=[^&\s]*(?:&[A-Za-z_][A-Za-z0-9_.-]*=[^&\s]*)+\z/

      SENSITIVE_QUERY_PARAMS = %w[
        access_token refresh_token id_token token api_key apikey client_secret
        password auth jwt session secret key code signature x-amz-signature
      ].to_set.freeze

      # ── Singleton resolution ──

      class << self
        # Returns the memoized redactor instance, resolved from config.
        # Custom class trumps built-in; missing/broken class logs a warning
        # and falls back to the built-in redactor.
        def resolve(config = Rubino.configuration)
          @resolved ||= build(config)
        end

        # For testing: clear the memoized instance.
        def reset!
          @resolved = nil
        end

        private

        def build(config)
          custom_class = config.dig("security", "redaction", "class")
          if custom_class && !custom_class.to_s.strip.empty?
            begin
              klass = Object.const_get(custom_class)
              return klass.new(config)
            rescue NameError, LoadError => e
              Rubino.logger&.warn(
                event: "redactor.custom_class_failed",
                class: custom_class, error: e.message
              )
            end
          end
          new(config)
        end
      end

      # ── Instance ──

      def initialize(config = Rubino.configuration)
        @config = config
        @custom_patterns = build_custom_patterns(config)
      end

      # Public interface: redact +text+ according to +profile+.
      # Returns text unchanged when redaction is disabled or profile is :none.
      def redact(text, profile: :shell, force: false)
        return text if text.nil? || profile == :none
        return text unless force || enabled?

        text = text.to_s unless text.is_a?(String)
        return text if text.empty?

        apply_custom_patterns(text)
        redact_secrets(text, code_file: profile == :code)
      end

      # ── Private helpers ──

      private

      def enabled?
        env = ENV.fetch("RUBINO_REDACT_SECRETS", nil)
        return %w[1 true yes on].include?(env.downcase) unless env.nil? || env.empty?

        @config.dig("security", "redact_secrets") != false
      rescue StandardError
        true
      end

      def build_custom_patterns(config)
        patterns = config.dig("security", "redaction", "custom_patterns") || []
        patterns.map { |p| Regexp.new(p) }
      rescue RegexpError => e
        Rubino.logger&.warn(event: "redactor.custom_pattern_invalid", error: e.message)
        []
      end

      def apply_custom_patterns(text)
        @custom_patterns.reduce(text) { |t, re| t.gsub(re) { mask_token(::Regexp.last_match(0)) } }
      end

      def mask_token(token)
        return FULL_MASK if token.nil? || token.empty?
        return FULL_MASK if token.length < 18

        "#{token[0, 6]}...#{token[-4, 4]}"
      end

      def redact_secrets(text, code_file:)
        text = text.gsub(PREFIX_RE) { mask_token(::Regexp.last_match(1)) }
        text = redact_assignments(text) unless code_file
        redact_misc_patterns(text)
      end

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

      def redact_misc_patterns(text)
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

      def redact_query_string(query)
        return query if query.nil? || query.empty?

        query.split("&").map do |pair|
          next pair unless pair.include?("=")

          key, = pair.partition("=")
          SENSITIVE_QUERY_PARAMS.include?(key.downcase) ? "#{key}=#{FULL_MASK}" : pair
        end.join("&")
      end

      def redact_form_body(text)
        return text if text.nil? || text.empty? || text.include?("\n") || !text.include?("&")
        return text unless FORM_BODY_RE.match?(text.strip)

        redact_query_string(text.strip)
      end
    end
  end
end
