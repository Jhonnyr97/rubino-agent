# frozen_string_literal: true

require "uri"

module Rubino
  module Config
    # Set-time schema validation for `config set` (#327). The Defaults hash is
    # the authoritative schema: a key the schema doesn't know, or a value whose
    # type/format can't match the seeded default, is REJECTED at write time with
    # a clear ConfigurationError (and a non-zero exit via ConfigCommand) instead
    # of being persisted with a green ✓ and only blowing up later — as a runtime
    # crash or a deterministic provider 4xx the agent then retries for ~85s.
    #
    # Two checks, intentionally narrow (false positives would block legitimate
    # config more than the original bug):
    #   * unknown key  — the path doesn't exist in Defaults AND isn't under an
    #                    open-map section (providers.<name>, quick_commands, …)
    #                    where arbitrary child keys are expected.
    #   * type / format — when the schema seeds a NON-nil scalar default at the
    #                    leaf, the coerced value must be the same coarse type
    #                    (numeric / boolean / string). A nil default carries no
    #                    type, so its leaf is type-unconstrained. A *_url leaf
    #                    additionally must parse as an http(s) URL.
    module Validator
      module_function

      # A per-provider leaf (providers.<name>.<leaf>) is type-checked against the
      # openai provider template, the canonical OpenAI-compatible provider shape,
      # so providers.minimax.request_timeout_seconds "soon" is still rejected.
      PROVIDER_TEMPLATE = "openai"

      # Top-level sections that are REAL config namespaces but intentionally not
      # seeded in Defaults (e.g. read at point-of-use with a fallback, or kept
      # unseeded on purpose). They are valid roots, so a key under them is not an
      # "unknown key" even though Defaults has no entry. The unknown-key check is
      # deliberately SHALLOW — it only rejects a typo'd TOP-LEVEL section (the
      # `foo.bar.baz` footgun from #327) — because the schema's leaves are
      # intentionally incomplete (model.api_key, display.reasoning, …), so a
      # deeper check would reject legitimate-but-unseeded keys. Type/format
      # checks still apply to every known leaf regardless.
      #   * sessions — read at point-of-use (Commands::Handlers::Sessions reads
      #                sessions.list_limit) with a fallback, not seeded.
      #   * oauth    — read at boot (OAuth::Registry reads oauth.providers.*)
      #                with a fallback, not seeded; without it `config set
      #                oauth.providers.github.client_id …` was rejected with the
      #                misleading "not a config section" typo error (H3).
      EXTRA_TOP_LEVEL_SECTIONS = %w[sessions oauth].freeze

      # Closed numeric ranges for the obvious bounded keys (#392b). A value that
      # type-checks as a number but falls outside its range used to be persisted
      # with a green ✓ (e.g. `model.temperature 9.9`) and only manifested as a
      # provider 4xx or nonsensical behaviour at call time. Keyed by the LEAF
      # name so the same bound applies wherever the key appears (model.* and the
      # per-provider/aux mirrors). Bounds are inclusive.
      RANGES = {
        "temperature" => (0.0..2.0),
        "threshold" => (0.0..1.0),
        "target_ratio" => (0.0..1.0)
      }.freeze

      # Leaves that must be a POSITIVE integer when set: a turn/iteration cap of
      # 0 or negative is nonsense (the turn could never run a single iteration)
      # and used to persist with a green ✓ then silently degrade to "unbounded" /
      # the default at runtime. Keyed by leaf name. A nil (clearing the key) is
      # left to the type-unconstrained nil-default path.
      POSITIVE_INT_LEAVES = %w[max_turns max_tool_iterations].freeze

      # Config keys that were REMOVED and are no longer honored (item 7). A
      # config.yml that still carries one isn't an "unknown key" (its top-level
      # section is real) and isn't a type error, so the generic checks miss it —
      # and the old key would be silently ignored. Map the FULL dotted path to a
      # bespoke warning that names the removed key and its replacement, surfaced
      # at load + in `rubino doctor` so the user migrates instead of believing a
      # stale setting still takes effect.
      REMOVED_KEYS = {
        "security.require_confirmation_for_shell" =>
          "`security.require_confirmation_for_shell` is removed — use " \
          "`security.confirm_policy` (dangerous_only|confirm_all)"
      }.freeze

      def validate!(key_path, keys, value)
        default = leaf_default(keys)
        reject_unknown_key!(key_path, keys) if default == :__absent__
        check_type!(key_path, keys, value, default) unless default == :__absent__
        check_range!(key_path, keys, value)
        check_positive_int!(key_path, keys, value)
        check_url_format!(key_path, keys, value)
      end

      # NON-raising counterpart of #validate!, run at LOAD time over a HAND-EDITED
      # config (F8). #validate! only fires at `config set`, so a config.yml edited
      # by hand with an unknown key or a wrong-typed value loaded SILENTLY and
      # only blew up later (a runtime crash, or a provider 4xx the agent retries
      # for ~85s). This walks every leaf of the RAW on-disk hash and returns a
      # list of human-readable WARNING strings (the same checks #validate! makes)
      # — surfaced at boot and by `rubino doctor`, never a crash. +raw+ is the
      # user's config.yml as loaded (Loader#raw_config), NOT merged with defaults
      # (defaults are valid by construction).
      def warnings(raw)
        return [] unless raw.is_a?(Hash)

        out = []
        each_leaf(raw) do |keys, value|
          # A REMOVED key (item 7) is flagged regardless of its value — it is no
          # longer honored, so we warn the moment it is PRESENT, before the
          # seeded-default skip (a removed key has no seeded default anyway).
          if (msg = REMOVED_KEYS[keys.join(".")])
            out << msg
            next
          end

          # Skip a leaf still at its seeded default: `setup` writes the FULL
          # default config to disk, so every default value is present in the raw
          # hash. Those are valid by construction (and a leaf-name RANGES
          # collision — e.g. doom_loop.threshold's count 5 vs a 0..1 ratio —
          # would otherwise mis-flag a value the user never touched). Only a leaf
          # the user CHANGED can be a hand-edit mistake.
          next if seeded_default?(keys, value)

          key_path = keys.join(".")
          validate!(key_path, keys, value)
        rescue ConfigurationError => e
          out << e.message
        rescue StandardError
          # A surprising shape must never crash a load — skip that leaf.
          nil
        end
        out
      end

      # True when +value+ at +keys+ equals the schema's seeded default — i.e. an
      # untouched leaf, not a user edit. :__absent__ (no such default) is never a
      # match, so an unknown key is still flagged.
      def seeded_default?(keys, value)
        default = leaf_default(keys)
        return false if default == :__absent__

        default == value
      end

      # Yields [keys_array, leaf_value] for every scalar/array leaf in a nested
      # config hash. Open-map sections (providers.<name>, quick_commands, …) are
      # walked the same way; the unknown-key check is intentionally shallow
      # (top-level only) so their arbitrary child keys are not flagged.
      def each_leaf(node, prefix = [], &block)
        node.each do |k, v|
          keys = prefix + [k.to_s]
          if v.is_a?(Hash)
            each_leaf(v, keys, &block)
          else
            block.call(keys, v)
          end
        end
      end

      # The seeded default at this exact path, or the sentinel :__absent__ when
      # the schema has no such leaf. providers.<name>.<leaf> resolves against the
      # openai template so a custom provider's known leaves still type-check.
      def leaf_default(keys)
        value = dig_default(keys)
        return value unless value == :__absent__
        return value unless keys.length >= 3 && keys.first == "providers"

        dig_default(["providers", PROVIDER_TEMPLATE, *keys[2..]])
      end

      def dig_default(keys)
        node = Defaults::MODULE_DEFAULTS
        keys.each do |k|
          return :__absent__ unless node.is_a?(Hash) && node.key?(k)

          node = node[k]
        end
        node
      end

      def reject_unknown_key!(key_path, keys)
        return if known_top_level?(keys.first)

        raise ConfigurationError,
              "unknown config key '#{key_path}': '#{keys.first}' is not a config " \
              "section. Run 'rubino config show' to see the valid sections"
      end

      # A top-level section is known when Defaults seeds it or it's one of the
      # documented intentionally-unseeded namespaces. Everything settable hangs
      # off one of these, so an UNKNOWN first segment is the typo we reject.
      def known_top_level?(section)
        Defaults::MODULE_DEFAULTS.key?(section) ||
          EXTRA_TOP_LEVEL_SECTIONS.include?(section)
      end

      def check_type!(key_path, keys, value, default)
        coerced = Writer.coerce_value(value)

        # A leaf with a declared RANGE is numeric by definition, so enforce its
        # type even when the seeded default is nil (e.g. model.temperature is now
        # nil to inherit the provider default, #414 — but `temperature banana`
        # must still be rejected, not silently stored as a string). A nil clears
        # the key and is allowed.
        if RANGES.key?(keys.last.to_s)
          return if coerced.nil? || coerced.is_a?(Numeric)

          raise ConfigurationError,
                "invalid value for '#{key_path}': expected number, got #{value.inspect}"
        end

        # Otherwise a nil default carries no type signal; leave it unconstrained.
        return if default.nil?

        expected = coarse_type(default)
        actual   = coarse_type(coerced)
        return if expected == actual
        # Numbers written as strings already coerced; an int is a fine float.
        return if expected == :number && actual == :number

        raise ConfigurationError,
              "invalid value for '#{key_path}': expected #{expected} " \
              "(default #{default.inspect}), got #{value.inspect}"
      end

      def coarse_type(value)
        case value
        when Numeric then :number
        when true, false then :boolean
        when String then :string
        when nil then :nil
        when Array then :array
        when Hash then :hash
        else :other
        end
      end

      # Range-check a bounded numeric leaf (#392b). Only applies when the leaf
      # name has a declared RANGE and the coerced value is numeric — a non-number
      # is already caught by check_type!, and a nil (clearing the key) is left to
      # the type-unconstrained nil-default path. Out of range is a hard reject
      # with a clear message + non-zero exit, like the other set-time footguns.
      def check_range!(key_path, keys, value)
        range = RANGES[keys.last.to_s]
        return unless range

        coerced = Writer.coerce_value(value)
        return unless coerced.is_a?(Numeric)
        return if range.cover?(coerced)

        raise ConfigurationError,
              "invalid value for '#{key_path}': #{coerced} is out of range " \
              "(expected #{range.begin}..#{range.end})"
      end

      # A turn/iteration cap leaf must be a POSITIVE integer when set. A 0 or
      # negative cap is nonsense (the turn could never run a single iteration);
      # it used to persist with a green ✓ then silently degrade to unbounded /
      # the default at runtime. A nil (clearing the key, "nil"/"null") is allowed
      # — it means "use the built-in default".
      def check_positive_int!(key_path, keys, value)
        return unless POSITIVE_INT_LEAVES.include?(keys.last.to_s)

        coerced = Writer.coerce_value(value)
        return if coerced.nil?
        return if coerced.is_a?(Numeric) && coerced.positive? && coerced == coerced.to_i

        raise ConfigurationError,
              "invalid value for '#{key_path}': #{value.inspect} — must be a positive " \
              "integer (a 0 or negative cap would never let the turn run)"
      end

      # A *_url / base_url leaf must be a real http(s) URL when a non-empty value
      # is given — exactly the providers.<name>.base_url "not a url" footgun from
      # #327, which otherwise persisted fine and only failed as a connection
      # error at the first model call.
      def check_url_format!(key_path, keys, value)
        leaf = keys.last.to_s
        return unless leaf == "base_url" || leaf.end_with?("_url")

        str = value.to_s.strip
        return if str.empty? || %w[nil null].include?(str.downcase)
        return if valid_http_url?(str)

        raise ConfigurationError,
              "invalid value for '#{key_path}': '#{value}' is not a valid http(s) URL"
      end

      def valid_http_url?(str)
        uri = URI.parse(str)
        uri.is_a?(URI::HTTP) && !uri.host.to_s.empty?
      rescue URI::InvalidURIError
        false
      end
    end
  end
end
