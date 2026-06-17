# frozen_string_literal: true

# Locale regression (#273). The built-in prompts carry non-ASCII glyphs
# (em-dashes). On a bare POSIX/C-locale system Ruby's default_external is
# US-ASCII, so a File.read without an explicit encoding tagged the bytes
# US-ASCII and #strip raised Encoding::CompatibilityError before the agent
# could boot. The registry must read its prompts as UTF-8 regardless of locale.
RSpec.describe Rubino::Agent::AgentRegistry do
  describe "prompt loading under a US-ASCII default_external" do
    around do |example|
      previous = Encoding.default_external
      Encoding.default_external = Encoding::US_ASCII
      example.run
    ensure
      Encoding.default_external = previous
    end

    it "builds the registry without raising on non-ASCII prompt bytes" do
      expect { described_class.new }.not_to raise_error
    end

    it "loads built-in prompts as valid UTF-8 with the glyphs preserved" do
      prompt = described_class.new.find("build").system_prompt

      expect(prompt.encoding).to eq(Encoding::UTF_8)
      expect(prompt).to be_valid_encoding
    end
  end
end
