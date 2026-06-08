# frozen_string_literal: true

# Regression: only UI::API#confirm accepted `scope:`, but
# ToolExecutor#request_approval ALWAYS passes `scope:`. In interactive mode
# Rubino.ui is UI::CLI, so any tool needing approval raised
# `ArgumentError: unknown keyword: :scope`. `scope:` is now part of the shared
# confirm contract on every adapter (CLI/Null ignore it; API uses it).
RSpec.describe "UI#confirm scope: parity" do
  ADAPTERS = [
    Rubino::UI::Base,
    Rubino::UI::CLI,
    Rubino::UI::Null,
    Rubino::UI::API
  ].freeze

  it "every adapter declares `scope:` as an optional keyword on #confirm" do
    ADAPTERS.each do |klass|
      params = klass.instance_method(:confirm).parameters
      keywords = params.select { |type, _| %i[key keyreq].include?(type) }.map(&:last)
      expect(keywords).to include(:scope), "#{klass} is missing the scope: keyword on #confirm"
    end
  end

  it "CLI and Null accept scope: without raising ArgumentError" do
    null = Rubino::UI::Null.new
    expect { null.confirm("ok?", scope: "shell:ls") }.not_to raise_error

    cli = Rubino::UI::CLI.allocate # avoid TTY setup; we only need arity here
    expect(cli.method(:confirm).parameters.map(&:last)).to include(:scope)
  end
end
