# frozen_string_literal: true

module Rubino
  module Attachments
    # Structural prompt-injection defense for inlined untrusted file content.
    # No blocklist of phrases (that arms race is unwinnable); instead we strip
    # the Unicode tricks that let attacker text visually escape our framing --
    # bidi/RTL overrides that reorder what the model reads, zero-width joiners
    # that hide payloads, and control chars that could fake a delimiter. NFKC
    # folds compatibility forms so confusables can't smuggle past the strip.
    # Pure stdlib (String#unicode_normalize), no gem.
    module Defang
      # Bidi controls + zero-width chars + BOM. Built from escapes so the
      # source stays ASCII-clean (no raw invisibles in the repo).
      BIDI_AND_ZERO_WIDTH = Regexp.union(
        "​", "‌", "‍", "‎", "‏", # ZWSP/ZWNJ/ZWJ/LRM/RLM
        "‪", "‫", "‬", "‭", "‮", # LRE/RLE/PDF/LRO/RLO
        "⁦", "⁧", "⁨", "⁩", # LRI/RLI/FSI/PDI
        "⁠", "﻿" # WJ / BOM
      ).freeze

      module_function

      # NFKC-normalize, strip bidi/zero-width, drop C0/C1 control chars except
      # \n and \t (legitimate in text/code). Returns a clean String safe to
      # wrap in the nonce frame.
      def call(text)
        s = text.to_s
        s = s.scrub("") unless s.valid_encoding?
        s = s.unicode_normalize(:nfkc)
        s = s.gsub(BIDI_AND_ZERO_WIDTH, "")
        strip_control(s)
      rescue ArgumentError, Encoding::CompatibilityError
        # unicode_normalize can choke on pathological input; fall back to a
        # raw strip so we never inline un-defanged bytes.
        strip_control(text.to_s.scrub("").gsub(BIDI_AND_ZERO_WIDTH, ""))
      end

      def strip_control(str)
        str.each_char.reject do |c|
          o = c.ord
          (o < 0x20 && o != 0x09 && o != 0x0A) || (o >= 0x7F && o <= 0x9F)
        end.join
      end
    end
  end
end
