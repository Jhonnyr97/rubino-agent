# frozen_string_literal: true

module Rubino
  module Attachments
    # Result of Attachments::Classify.call. Pure data; no behaviour.
    #   path:       frozen realpath captured once (TOCTOU), or original if unsafe
    #   kind:       :image | :text | :document | :archive | :binary
    #   mime:       Marcel content-sniffed type
    #   safe:       false => safety pipeline rejected it; caller skips + warns
    #   reason:     human-readable why-unsafe / how-classified
    Classification = Struct.new(
      :path, :kind, :mime, :size_bytes, :safe, :reason,
      keyword_init: true
    )
  end
end
