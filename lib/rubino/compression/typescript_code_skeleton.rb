# frozen_string_literal: true

module Rubino
  module Compression
    # The TypeScript strategy: TreeSitterCodeSkeleton with the `typescript`
    # grammar. Optional gem, no-op when absent (see TreeSitterCodeSkeleton).
    class TypescriptCodeSkeleton < TreeSitterCodeSkeleton
      private

      def grammar_name
        "typescript"
      end
    end
  end
end
