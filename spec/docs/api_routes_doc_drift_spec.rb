# frozen_string_literal: true

require "spec_helper"

# Doc-drift guard (#167): docs/api/v1.md presents itself as the canonical /v1
# surface, yet GET /v1/sessions (index), /v1/memory* and /v1/tasks* were
# registered but undocumented. Lock the documented route catalogue to the
# routes ServerCommand actually registers — adding/renaming/removing a route
# fails the suite until the API reference is updated to match.
RSpec.describe Rubino::CLI::ServerCommand do
  it "has every registered /v1 route documented in docs/api/v1.md, and nothing else" do
    source = File.read(File.expand_path("../../lib/rubino/cli/server_command.rb", __dir__))
    registered = source.scan(/router\.(get|post|put|patch|delete)\s+"([^"]+)"/)
                       .map { |method, path| "#{method.upcase} #{path}" }
    expect(registered).not_to be_empty

    doc = File.read(File.expand_path("../../docs/api/v1.md", __dir__))
    # Endpoint headings: ### `METHOD /v1/path` → ... (query strings after "?"
    # are display sugar, not part of the route).
    documented = doc.scan(%r{^### `(GET|POST|PUT|PATCH|DELETE) (/v1/[^`?\s]*)})
                    .map { |method, path| "#{method} #{path}" }

    expect(documented.sort).to eq(registered.sort)
  end
end
