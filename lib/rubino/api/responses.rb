# frozen_string_literal: true

require "json"

module Rubino
  module API
    # Coerces Operation return values into Rack response triples.
    # Lets operations return whatever shape is most convenient (a plain Hash for
    # 200, a [status, body] pair for other codes, or a full Rack triple for
    # streaming/binary), while the router always hands Rack a valid triple.
    module Responses
      module_function

      # Builds a JSON response triple with content-type set.
      #
      # @return [Array(Integer, Hash, Array<String>)]
      def json(status, payload)
        [status, { "content-type" => "application/json" }, [JSON.generate(payload)]]
      end

      # @return [Array(Integer, Hash, Array)] empty 204 response triple
      def no_content
        [204, {}, []]
      end

      # Normalize an operation result. See Router class comment for the contract.
      #
      # @param value [Hash, Array, #to_rack]
      # @return [Array(Integer, Hash, Array<String>)] Rack triple
      # @raise [ArgumentError] when value doesn't match any supported shape
      def coerce(value)
        case value
        when Array
          coerce_array(value)
        when Hash
          json(200, value)
        else
          return value.to_rack if value.respond_to?(:to_rack)

          raise ArgumentError, "operation returned unsupported value: #{value.class}"
        end
      end

      # Disambiguates [status, body] (length 2, JSON-encoded) from a raw
      # [status, headers, body] Rack triple (length 3, passed through).
      def coerce_array(value)
        case value.length
        when 2
          status, body = value
          # RFC 7231 §6.3.5: a 204 response MUST NOT have a message body. We
          # force the body to "" regardless of what the operation returned so
          # we never emit `null\n` (a 4-byte JSON literal) for a No Content.
          return [status, {}, [""]] if status == 204

          json(status, body)
        when 3
          value
        else
          raise ArgumentError, "operation returned array of length #{value.length}; expected 2 or 3"
        end
      end
    end
  end
end
