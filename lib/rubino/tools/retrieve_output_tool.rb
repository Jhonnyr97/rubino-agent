# frozen_string_literal: true

module Rubino
  module Tools
    # Returns the ORIGINAL, uncompressed command output that the log compressor
    # stashed (Compression::OutputStore), keyed by the sha256 the compressed
    # output's pointer line carries. This is the reversibility seam: the model
    # drops passing/info noise from context cheaply, but the full bytes are one
    # `retrieve_output` away when it actually needs them.
    class RetrieveOutputTool < Base
      def name
        "retrieve_output"
      end

      def config_key
        # Gated by the same flag that produced the pointer in the first place;
        # with log compression off, no pointer is ever emitted, so the tool is
        # inert. Falls under the `shell` toolset for enable/disable.
        "shell"
      end

      def description
        "Retrieve the full, uncompressed output of an earlier command that was " \
          "shortened by log compression. Pass the `hash` from the pointer line " \
          "(`… hidden by log compression … hash=<sha>`)."
      end

      def input_schema
        {
          type: "object",
          properties: {
            hash: {
              type: "string",
              description: "The sha256 from the compressed output's pointer line."
            }
          },
          required: %w[hash]
        }
      end

      def risk_level
        :low
      end

      def call(arguments)
        hash = (arguments["hash"] || arguments[:hash]).to_s.strip
        return "Error: hash is required" if hash.empty?

        text = Compression::OutputStore.instance.get(hash)
        return "Error: no stored output for hash=#{hash} (it may have been evicted; re-run the command)." if text.nil?

        text
      end
    end
  end
end
