# frozen_string_literal: true

module Rubino
  module Tools
    # Summarizes a large text file WITHOUT pulling its bytes into the main agent
    # context. The file is chunked and map-reduced through the `summarize`
    # auxiliary LLM; only the final summary string returns to the caller. This
    # is the in-house realization of the "summarization subagent" pattern: the
    # raw 30k-line document lives only in the aux calls, so it never bloats the
    # primary prompt (which is what pushes time-to-first-token past the
    # provider's stream idle-timeout and gets a run cut mid-stream).
    #
    # Algorithm (LangChain/OpenAI-cookbook map-reduce):
    #   1. MAP   — split the file into ~CHUNK_BYTES chunks, summarize each.
    #   2. REDUCE— combine the chunk summaries; if the combined text still
    #              overflows a chunk, group + re-summarize recursively (capped).
    class SummarizeFileTool < Base
      # ~6k tokens/chunk at 4 bytes/token — leaves room for the prompt and the
      # chunk's own summary inside a modest context window.
      CHUNK_BYTES      = 24_000
      # Refuse absurdly large inputs rather than fan out hundreds of LLM calls.
      MAX_FILE_BYTES   = 8_000_000
      # Bound the reduce recursion so a pathological fan-in can't loop forever.
      REDUCE_DEPTH_CAP = 4
      GROUP_SIZE       = 5
      AUX_TASK         = "summarize"

      # Test seam: inject a stub LLM client. Production lazily builds the real
      # AuxiliaryClient, which routes to the `auxiliary.summarize` config.
      attr_writer :aux_client

      def name
        "summarize_file"
      end

      def description
        "Summarize a large text file WITHOUT loading it into this conversation. " \
          "The file is read and map-reduced by a separate summarization model; only the " \
          "final summary returns here, so the raw bytes never enter context. " \
          "PREFER this over `read` whenever you need the gist of a big document — converted " \
          "PDFs, logs, transcripts, anything more than a few hundred lines. For binary docs " \
          "(PDF/DOCX) convert to text first (e.g. markitdown), then summarize the text file. " \
          "Use `focus` to steer what the summary must preserve."
      end

      def input_schema
        {
          type: "object",
          properties: {
            file_path: { type: "string", description: "Absolute or relative path to a text file" },
            focus: { type: "string",
                     description: "What the summary must preserve, e.g. 'chapter titles and page numbers' or 'API errors with timestamps'. Optional." },
            max_words: { type: "integer",
                         description: "Approximate length of the final summary in words (default 500)." }
          },
          required: %w[file_path]
        }
      end

      def risk_level
        :low
      end

      def call(arguments)
        file_path = arguments["file_path"] || arguments[:file_path]
        focus     = (arguments["focus"] || arguments[:focus]).to_s.strip
        focus     = "the key facts, structure, decisions, and any errors" if focus.empty?
        max_words = (arguments["max_words"] || arguments[:max_words] || 500).to_i.clamp(50, 4000)

        return "Error: file_path is required" if file_path.nil? || file_path.to_s.empty?

        expanded = File.expand_path(file_path)
        return "Error: File not found: #{file_path}" unless File.exist?(expanded)
        return "Error: Not a regular file: #{file_path}" unless File.file?(expanded)

        size = File.size(expanded)
        return "#{file_path} is empty — nothing to summarize." if size.zero?
        if binary?(expanded)
          return "Error: #{file_path} looks binary. Convert it to text first " \
                 "(e.g. `markitdown #{file_path} > out.md`), then summarize the text file."
        end
        if size > MAX_FILE_BYTES
          return "Error: #{file_path} is #{size / 1_000_000}MB, over the " \
                 "#{MAX_FILE_BYTES / 1_000_000}MB summarize cap. Split it (e.g. with split/sed) " \
                 "or grep to the relevant section, then summarize that."
        end

        chunks = chunk_file(expanded)
        return "#{file_path} is empty — nothing to summarize." if chunks.empty?

        summaries = chunks.each_with_index.map do |chunk, i|
          raise Rubino::Interrupted if cancellation_requested?

          emit_chunk("summarizing chunk #{i + 1}/#{chunks.size}…\n")
          map_summarize(chunk, focus)
        end

        summary = reduce(summaries, focus, max_words)
        {
          output: summary,
          metrics: "#{chunks.size} chunk#{"s" if chunks.size != 1} → summary"
        }
      rescue Rubino::Interrupted
        raise
      rescue StandardError => e
        "Error summarizing #{file_path}: #{e.message}"
      end

      private

      def aux_client
        @aux_client ||= LLM::AuxiliaryClient.new
      end

      # Streams the file into ~CHUNK_BYTES blocks on line boundaries so we never
      # slurp a multi-MB file whole, and a chunk never splits a line.
      def chunk_file(path)
        chunks = []
        buf    = +""
        File.foreach(path) do |line|
          buf << line
          if buf.bytesize >= CHUNK_BYTES
            chunks << buf
            buf = +""
          end
        end
        chunks << buf unless buf.empty?
        chunks
      end

      def map_summarize(chunk, focus)
        complete(
          "Write a concise summary of the following text, preserving #{focus}. " \
          "This is only PART of a larger document, so do NOT conclude with wording " \
          "like \"Finally\" or \"In conclusion\".\n\n" \
          "#{chunk}\n\nCONCISE SUMMARY:"
        )
      end

      # Combine chunk summaries into one. If the combined summaries still
      # overflow a chunk, group and re-summarize recursively (tree reduce).
      def reduce(summaries, focus, max_words, depth = 0)
        return summaries.first.to_s if summaries.size <= 1

        combined = summaries.join("\n\n")
        if combined.bytesize <= CHUNK_BYTES || depth >= REDUCE_DEPTH_CAP
          return complete(
            "Combine these partial summaries of one document into a single coherent " \
            "summary of about #{max_words} words, preserving #{focus}. Remove redundancy " \
            "and keep it well-structured.\n\n#{combined}\n\nFINAL SUMMARY:"
          )
        end

        regrouped = summaries.each_slice(GROUP_SIZE).map do |group|
          raise Rubino::Interrupted if cancellation_requested?

          map_summarize(group.join("\n\n"), focus)
        end
        reduce(regrouped, focus, max_words, depth + 1)
      end

      def complete(prompt)
        response = aux_client.call(task: AUX_TASK, messages: [{ role: "user", content: prompt }])
        text = response.respond_to?(:content) ? response.content.to_s : response.to_s
        text.strip
      end

      # Light binary guard: a NUL byte in the first KB. summarize_file is for
      # text; binary docs must be converted upstream.
      def binary?(path)
        sample = File.binread(path, 1024)
        return false if sample.nil? || sample.empty?

        sample.include?("\x00")
      rescue Errno::ENOENT, Errno::EACCES
        false
      end
    end
  end
end
