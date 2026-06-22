# frozen_string_literal: true

module Rubino
  module Security
    # The ONE whitespace/line-continuation normalizer shared by the two
    # string-blocklist layers (HardlineGuard and DangerousPatterns). Keeping a
    # single normalizer is a correctness requirement, not a convenience: if the
    # two layers normalize differently, a command can slip past one while the
    # other catches it — exactly the shell line-continuation evasion that #348
    # closed for HardlineGuard but had silently re-opened for DangerousPatterns
    # (`rm -r\<newline>f /`).
    #
    # CASE-PRESERVING on purpose. Layers that need a lowercased form append
    # `.downcase` themselves; the case-sensitive sudo-stdin guard relies on the
    # case being preserved here.
    #
    # Steps (mirrors the prior HardlineGuard idiom exactly):
    #   1. Fold shell line-continuations: a backslash immediately before a
    #      newline is a `\<newline>` pair the shell deletes ENTIRELY — it does
    #      NOT insert a space. So `rm -r\<newline>f /` folds to `rm -rf /`, the
    #      glued form the rm/dd/etc. patterns expect. Replacing with a space
    #      instead would split `-rf` into `-r f` and miss the pattern.
    #   2. Collapse runs of spaces/tabs to a single space (real newlines are
    #      KEPT — both layers anchor command-separator patterns on them).
    #   3. Strip leading/trailing whitespace.
    module CommandNormalizer
      module_function

      # Case-preserving whitespace + line-continuation normalization.
      def normalize(command)
        joined = command.to_s.gsub(/\\\r?\n/, "")
        joined.gsub(/[ \t]+/, " ").strip
      end
    end
  end
end
