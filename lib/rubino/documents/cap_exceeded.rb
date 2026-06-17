# frozen_string_literal: true

module Rubino
  module Documents
    # Raised by a Limits::Budget when a conversion blows a resource cap (too
    # many elements, too many decompressed bytes, or the wall-clock budget) --
    # i.e. a decompression bomb or runaway document. A plain StandardError so
    # `Documents.to_markdown` rescues it and degrades to nil -> the caller emits
    # the actionable shell-extraction hint, exactly like an unsupported format.
    # NEVER let a bomb hang/OOM the turn; bail clean.
    class CapExceeded < StandardError; end
  end
end
