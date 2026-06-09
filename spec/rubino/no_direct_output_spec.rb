# frozen_string_literal: true

# This spec ensures that no core module uses puts/print/warn directly.
# All output must go through the UI layer.
RSpec.describe "No direct output in core modules" do
  CORE_PATHS = %w[
    lib/rubino/agent
    lib/rubino/context
    lib/rubino/config
    lib/rubino/database
    lib/rubino/interaction
    lib/rubino/jobs
    lib/rubino/llm
    lib/rubino/memory
    lib/rubino/session
    lib/rubino/security
    lib/rubino/tools
  ].freeze

  FORBIDDEN_PATTERNS = /^\s*(puts|print|warn|STDOUT|STDERR|pp )\b/

  CORE_PATHS.each do |dir_path|
    full_path = File.expand_path("../../#{dir_path}", __dir__)
    next unless File.directory?(full_path)

    Dir.glob("#{full_path}/**/*.rb").each do |file|
      relative = file.sub(File.expand_path("../../", __dir__) + "/", "")

      it "#{relative} does not use direct output" do
        content = File.read(file)
        lines_with_output = content.each_line.with_index(1).select { |line, _| line.match?(FORBIDDEN_PATTERNS) }

        offending = lines_with_output.map { |line, num| "  line #{num}: #{line.strip}" }
        expect(offending).to be_empty,
                             "Found direct output in #{relative}:\n#{offending.join("\n")}"
      end
    end
  end
end
