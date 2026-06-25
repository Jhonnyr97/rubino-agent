# frozen_string_literal: true

module Rubino
  module Compression
    # The JavaScript strategy: TreeSitterCodeSkeleton with the `javascript`
    # grammar. Optional gem, no-op when absent (see TreeSitterCodeSkeleton).
    class JavascriptCodeSkeleton < TreeSitterCodeSkeleton
      private

      def grammar_name
        "javascript"
      end
    end
  end
end
