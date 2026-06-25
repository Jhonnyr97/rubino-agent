# frozen_string_literal: true

module Rubino
  module Compression
    # The TSX strategy: TreeSitterCodeSkeleton with the `tsx` grammar (TypeScript
    # + JSX). Optional gem, no-op when absent (see TreeSitterCodeSkeleton).
    class TsxCodeSkeleton < TreeSitterCodeSkeleton
      private

      def grammar_name
        "tsx"
      end
    end
  end
end
