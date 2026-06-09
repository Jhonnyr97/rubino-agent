# frozen_string_literal: true

# #67: an unknown subcommand must exit non-zero so a typo'd invocation can't
# be mistaken for success by scripts/CI. Thor provides this via the
# `exit_on_failure?` hook; this spec locks the contract.
RSpec.describe Rubino::CLI::Commands do
  describe "unknown command exit status (#67)" do
    it "exits non-zero and reports the unknown command" do
      status = nil
      expect do
        described_class.start(["frobnicate"])
      rescue SystemExit => e
        status = e.status
      end.to output(/Could not find command "frobnicate"/).to_stderr

      expect(status).to eq(1)
    end

    it "exits non-zero for an unknown nested subcommand" do
      status = nil
      expect do
        described_class.start(%w[sessions frobnicate])
      rescue SystemExit => e
        status = e.status
      end.to output(/Could not find command "frobnicate"/).to_stderr

      expect(status).to eq(1)
    end
  end
end
