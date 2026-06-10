# frozen_string_literal: true

RSpec.describe Rubino::CLI::Commands do
  # #20: Thor clamps the top-level --help description column to the terminal
  # width and cuts with "..." (often mid-word). Keep every command's one-liner
  # short enough that the full "  rubino <usage>  # <desc>" line fits a
  # standard 80-column terminal, so nothing truncates.
  describe "top-level help hygiene (#20)" do
    it "keeps every command's help line within 80 columns" do
      described_class.printable_commands(true).each do |usage, desc|
        # The banner leads with $0 (the spec runner here); normalize to the
        # installed binary name so the budget matches a real `rubino --help`.
        line = "  rubino #{usage.sub(/\A\S+\s+/, "")}  #{desc}"
        expect(line.length).to be <= 80,
                               "help line overflows 80 cols (#{line.length}): #{line.inspect}"
      end
    end

    it "renders the TLS command as tls_cert in help, matching `tree`" do
      usages = described_class.printable_commands(true).map(&:first)
      expect(usages.join("\n")).to include("tls_cert")
      expect(usages.join("\n")).not_to include("tls-cert")
      # `tree` prints the registered command names — same spelling.
      expect(described_class.commands.keys).to include("tls_cert")
    end
  end
end
