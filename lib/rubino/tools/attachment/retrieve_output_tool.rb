# frozen_string_literal: true

module Rubino
  module Tools
    # Recovers the full, uncompressed output of an earlier tool call by its id.
    #
    # When tool-output compression hides lower-signal lines, the executor spills
    # the verbatim original to <home>/tool-results/<sanitized id>.txt and the
    # compressed view ends with a pointer carrying that id. This tool reads that
    # file back — the ONLY recovery path (there is deliberately no cat-able
    # filesystem path in the model-facing pointer, so a small model can't
    # `sed`/`grep`/`cat` the spill and re-inflate the very output compression
    # just shrank). Registered only while compression is enabled.
    #
    # Read-only and low risk: it reads exclusively from the agent's own
    # tool-results dir, sanitizing the id the SAME way ToolExecutor#spill_full_output
    # sanitizes the call_id, so a `../` in the id can't traverse out.
    class RetrieveOutputTool < Base
      description "Retrieve the full, uncompressed output of an earlier tool call by its id — " \
                  "use ONLY when a specific hidden line is needed; the compressed view already " \
                  "keeps the important content (errors/failures, summary, changes)."

      param :id, required: true,
                 desc: "The id printed in a compression pointer (retrieve_output id=…)."

      # Gate on the SAME key the compression feature uses, so it disappears from
      # the registry whenever compression is off (the default).
      def config_key
        "tool_output_compression"
      end

      def execute(id:)
        # Sanitize identically to ToolExecutor#spill_full_output so the id maps
        # to the same file, and a traversal attempt collapses to underscores.
        safe_id = id.to_s.gsub(/[^a-zA-Z0-9_.-]/, "_")

        path = File.join(Rubino.home_path, "tool-results", "#{safe_id}.txt")
        return "No stored output for id=#{safe_id} (it may have expired)." unless File.file?(path)

        File.read(path)
      rescue StandardError => e
        "Error: could not retrieve output for id=#{safe_id}: #{e.message}"
      end
    end
  end
end
