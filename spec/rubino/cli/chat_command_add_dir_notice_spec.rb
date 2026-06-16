# frozen_string_literal: true

require "stringio"

# F6: in one-shot/headless mode the stdout answer must stay pipe-clean (#418),
# so a `--add-dir` status/error notice belongs on STDERR — not on the styled
# ui (stdout). Interactive mode keeps the styled ui notice.
RSpec.describe Rubino::CLI::ChatCommand do
  subject(:cmd) { described_class.new({}) }

  let(:ui) { Rubino::UI::Null.new }

  def capture_stderr
    old = $stderr
    $stderr = StringIO.new
    yield
    $stderr.string
  ensure
    $stderr = old
  end

  describe "#dir_notice" do
    it "routes a status notice to STDERR (not the ui) when headless" do
      err = capture_stderr do
        cmd.send(:dir_notice, ui, "added workspace ~/x", interactive: false)
      end
      expect(err).to include("added workspace ~/x")
      expect(ui.messages).to be_empty
    end

    it "routes an error notice to STDERR with a rubino: prefix when headless" do
      err = capture_stderr do
        cmd.send(:dir_notice, ui, "--add-dir /no/such: nope", interactive: false, error: true)
      end
      expect(err).to include("rubino: --add-dir /no/such: nope")
      expect(ui.messages).to be_empty
    end

    it "uses the styled ui (stdout path) when interactive" do
      err = capture_stderr do
        cmd.send(:dir_notice, ui, "added workspace ~/x", interactive: true)
      end
      expect(err).to be_empty
      expect(ui.messages).to include(hash_including(level: :status, message: a_string_matching(/added workspace/)))
    end

    it "uses ui.error when interactive + error" do
      cmd.send(:dir_notice, ui, "--add-dir bad: nope", interactive: true, error: true)
      expect(ui.messages).to include(hash_including(level: :error, message: a_string_matching(/--add-dir bad/)))
    end
  end
end
