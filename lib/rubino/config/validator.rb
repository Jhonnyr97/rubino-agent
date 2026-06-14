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

      # Sections whose CHILD keys are open-ended maps (provider names, custom
      # command/permission/agent ids, MCP server names, per-role prompt
      # overrides). A path that descends through one of these stops being
      # checked for "unknown key" past the open node — but its leaf is still
      # type/format-checked against any matching default template.
      OPEN_MAP_PREFIXES = [
        %w[providers],
        %w[auxiliary],
        %w[quick_commands],
        %w[permissions],
        %w[formatters],
        %w[agents],
        %w[mcp servers],
        %w[prompts overrides]
      ].freeze

      # A per-provider leaf (providers.<name>.<leaf>) is type-checked against the
      # openai provider template, the canonical OpenAI-compatible provider shape,
      # so providers.minimax.request_timeout_seconds "soon" is still rejected.
      PROVIDER_TEMPLATE = "openai"

      def validate!(key_path, keys, value)
        default = leaf_default(keys)
        reject_unknown_key!(key_path, keys) if default == :__absent__
        check_type!(key_path, keys, value, default) unless default == :__absent__
        check_url_format!(key_path, keys, value)
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
        return if under_open_map?(keys)

        raise ConfigurationError,
              "unknown config key '#{key_path}'. Run 'rubino config show' to see " \
              "the valid keys (or 'rubino config tree' for the command list)"
      end

      # True when the path descends THROUGH a known open-map section (so the
      # unknown segment is an expected free-form child key, e.g. a provider or
      # MCP server name), rather than a genuine typo at a fixed-schema path.
      def under_open_map?(keys)
        OPEN_MAP_PREFIXES.any? do |prefix|
          keys.length > prefix.length && keys[0, prefix.length] == prefix
        end
      end

      def check_type!(key_path, keys, value, default)
        # A nil default carries no type signal; leave it unconstrained.
        return if default.nil?

        coerced  = Writer.coerce_value(value)
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
