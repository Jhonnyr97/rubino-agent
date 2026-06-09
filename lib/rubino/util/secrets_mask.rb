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
        text.to_s.gsub(INLINE_RE) do
          m   = Regexp.last_match
          val = m[:val]
          masked = case val[0]
                   when '"' then %("#{MASK}")
                   when "'" then "'#{MASK}'"
                   else MASK
                   end
          "#{m[:key]}#{m[:sep]}#{masked}"
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
