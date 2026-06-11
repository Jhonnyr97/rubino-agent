# frozen_string_literal: true

module Rubino
  module Documents
    module Converters
      # Plain text / source code -> Markdown. The last-resort converter: it
      # accepts any text/* MIME (and is the registry's final fallback). Markdown
      # passes through unchanged; other source files are wrapped in a fenced code
      # block tagged with the language inferred from the extension, so the model
      # sees the code as code, not prose. Encoding is normalised to UTF-8.
      class Plain
        # Extension -> fenced-code language hint. Markdown/plain text are NOT
        # fenced (they pass through). Anything else with a known mapping fences.
        LANGS = {
          ".rb" => "ruby", ".py" => "python", ".js" => "javascript",
          ".ts" => "typescript", ".jsx" => "jsx", ".tsx" => "tsx",
          ".go" => "go", ".rs" => "rust", ".java" => "java", ".c" => "c",
          ".h" => "c", ".cpp" => "cpp", ".cc" => "cpp", ".hpp" => "cpp",
          ".cs" => "csharp", ".php" => "php", ".rb_" => "ruby",
          ".sh" => "bash", ".bash" => "bash", ".zsh" => "bash",
          ".sql" => "sql", ".yml" => "yaml", ".yaml" => "yaml",
          ".toml" => "toml", ".ini" => "ini", ".css" => "css",
          ".scss" => "scss", ".swift" => "swift", ".kt" => "kotlin",
          ".lua" => "lua", ".pl" => "perl", ".r" => "r"
        }.freeze

        MARKDOWN_EXTS = %w[.md .markdown .mdown .mkd].freeze

        def available?
          true
        end

        # Accepts anything textual: text/* MIME, the textual application/* types,
        # or -- as the final fallback -- a file with a known code/markdown
        # extension even when MIME is unknown.
        def accepts?(mime, path)
          m = mime.to_s
          return true if m.start_with?("text/")
          return true if textual_application?(m)

          ext = File.extname(path.to_s).downcase
          MARKDOWN_EXTS.include?(ext) || LANGS.key?(ext)
        end

        def convert(path)
          raw = File.binread(path).to_s.dup.force_encoding("UTF-8")
          raw = raw.scrub("�") unless raw.valid_encoding?
          ext = File.extname(path.to_s).downcase

          return raw if MARKDOWN_EXTS.include?(ext)

          lang = LANGS[ext]
          return raw if lang.nil? # unknown text: pass through as-is

          "```#{lang}\n#{raw.chomp}\n```\n"
        end

        private

        def textual_application?(mime)
          mime == "application/json" || mime == "application/xml" ||
            mime == "application/javascript" || mime == "application/x-yaml" ||
            mime.end_with?("+json") || mime.end_with?("+xml")
        end
      end
    end
  end
end
