# frozen_string_literal: true

module Rubino
  module Util
    # Heuristic masking for credentials in tool arguments. The model often
    # passes secrets through cleanly (env vars, config files), but a stray
    # `command: "curl -H 'Authorization: Bearer sk_live_…'"` showing up in
    # an approval prompt — or, worse, in the persistent scrollback — is a
    # leak waiting to happen. Mask aggressively on display; the underlying
    # tool still receives the real value.
    module SecretsMask
      SECRET_KEY_TOKENS = %w[
        password passwd
        secret
        token bearer
        api_key apikey api-key
        access_key accesskey access-key
        private_key privatekey private-key
        auth authorization
      ].freeze

      # Pattern that matches `key=value`, `key: value`, `key value` for the
      # secret-named keys, inside a free-text string (shell command, URL
      # query). The trailing value is grabbed up to whitespace or a known
      # delimiter; quoted values are grabbed whole. `Bearer <token>` is
      # treated as a single value so `Authorization: Bearer XYZ` masks
      # the whole token instead of leaving XYZ exposed.
      INLINE_RE = /
        (?<key>password|passwd|secret|token|
              api[_-]?key|access[_-]?key|private[_-]?key|
              authorization|auth|bearer)
        (?<sep>\s*[:=]\s*|\s+)
        (?<val>"[^"]+"|'[^']+'|(?:Bearer\s+)?[^"'\s]+)
      /xi

      # URL userinfo credentials: `scheme://user:PASSWORD@host`. Masks ONLY the
      # password, keeping scheme/user/host so the trace still says which
      # service/account was touched (`postgresql://app:***@db`). The userinfo
      # username is `[^:@/\s]+` and the password `[^@/\s]+`, both terminating at
      # the `@`, so a bare `https://host:8080/p` (no `@`), the `host:port` that
      # follows the `@`, and an IPv6 host `@[::1]:5432` are all left untouched —
      # only a real `user:pass@` triggers. The unambiguous, industry-standard
      # form (git/pip redact credentials in URLs exactly this way; RFC 3986
      # deprecates them outright).
      URL_USERINFO_RE = %r{
        (?<scheme>[a-z][a-z0-9+.-]*://)
        (?<user>[^:@/\s]+)
        (?<sep>:)
        (?<pass>[^@/\s]+)
        (?<at>@)
      }xi

      # Basic-auth credential pair `-u user:pass` (curl/wget). Unambiguous: the
      # value carries a colon-separated `user:pass`, so we mask the password half
      # and keep the username (`-u admin:***`). Both glued (`-uadmin:pw`) and
      # spaced (`-u admin:pw`) forms match; a bare username with no colon is left
      # alone (no secret on the line to mask).
      U_FLAG_CRED_RE = /
        (?<flag>(?<![\w-])-u)
        (?<sp>\s*)
        (?<user>[^\s:'"]+)
        (?<sep>:)
        (?<pass>[^\s'"]+)
      /x

      # Glued DB-client password flag `-p<password>`, scoped to mysql/mariadb
      # clients ONLY. `-p<val>` is a password there but a PORT/PATH/anything for
      # most other tools (`ssh -p 22`, `kubectl -p`), so we require BOTH the
      # value to be GLUED to the flag (`-pSECRET`, no space — mysql's own
      # convention) AND a mysql-family client word on the same command. A
      # generic `-p 8080` is never masked, and the spaced `mysql -p` (interactive
      # prompt) carries no secret on the line so there is nothing to mask.
      MYSQL_PFLAG_RE = /
        (?<client>\b(?:mysql|mysqldump|mariadb|mariadb-dump)\b[^\n|;&]*?\s)
        (?<flag>-p)
        (?<pass>[^\s'"]+)
      /xi

      MASK = "***"

      # True if the given key looks sensitive on its own (used when the
      # caller already has key/value pairs, e.g. a Hash of arguments).
      def self.sensitive_key?(key)
        k = key.to_s.downcase.tr("-", "_")
        SECRET_KEY_TOKENS.any? { |t| k == t.tr("-", "_") || k.include?(t.tr("-", "_")) }
      end

      # Mask a single value, given the key it belongs to. Returns MASK if
      # the key is sensitive; otherwise scans the value for inline secrets.
      def self.mask_value(value, key: nil)
        return value if value.nil?
        return MASK if key && sensitive_key?(key)

        mask_inline(value.to_s)
      end

      # Mask inline patterns like `Authorization: Bearer XYZ` in any string,
      # whether or not the caller knows the surrounding context. Quoted
      # values keep their quotes around the mask so the surrounding
      # structure (`-H "Authorization: ***"`) stays balanced — otherwise
      # the mask would eat a quote and the rest of the string would look
      # like one long open string.
      def self.mask_inline(text)
        masked = text.to_s.gsub(INLINE_RE) do
          m   = Regexp.last_match
          val = m[:val]
          inner = case val[0]
                  when '"' then %("#{MASK}")
                  when "'" then "'#{MASK}'"
                  else MASK
                  end
          "#{m[:key]}#{m[:sep]}#{inner}"
        end
        mask_glued_credentials(masked)
      end

      # The glued/URL credential forms the keyed INLINE_RE can't see: URL
      # userinfo passwords, `-u user:pass`, and mysql/mariadb `-p<password>`.
      # Each keeps the surrounding, non-secret context (scheme/user/host, the
      # flag, the username) so the trace stays useful while the secret is gone.
      def self.mask_glued_credentials(text)
        out = text.gsub(URL_USERINFO_RE) do
          m = Regexp.last_match
          "#{m[:scheme]}#{m[:user]}:#{MASK}@"
        end
        out = out.gsub(U_FLAG_CRED_RE) do
          m = Regexp.last_match
          "#{m[:flag]}#{m[:sp]}#{m[:user]}:#{MASK}"
        end
        out.gsub(MYSQL_PFLAG_RE) do
          m = Regexp.last_match
          "#{m[:client]}#{m[:flag]}#{MASK}"
        end
      end

      # Convenience for Hash arguments: returns a new Hash with sensitive
      # values masked, leaving the original untouched (the real value still
      # has to reach the tool).
      def self.mask_hash(hash)
        return hash unless hash.is_a?(Hash)

        hash.each_with_object({}) { |(k, v), out| out[k] = mask_value(v, key: k) }
      end
    end
  end
end
