# frozen_string_literal: true

require "json"
require "stringio"

# F10: `--json --output-format xml` used to short-circuit to :json on the
# --json alias BEFORE validating the explicit --output-format, so the bogus
# `xml` was silently ignored and the run exited 0. An invalid --output-format
# is always an error — validate it even when --json is also present, rejecting
# `xml`/bogus with the clean "invalid --output-format" message + exit 2.
RSpec.describe Rubino::CLI::ChatCommand do
  def run_oneshot(opts)
    out = StringIO.new
    err = StringIO.new
    status = 0
    orig_out = $stdout
    orig_err = $stderr
    $stdout = out
    $stderr = err
    begin
      described_class.new(opts).execute
    rescue SystemExit => e
      status = e.status
    ensure
      $stdout = orig_out
      $stderr = orig_err
    end
    [out.string, err.string, status]
  end

  describe "--output-format validation (F10)" do
    it "rejects a bogus format with exit 2 and a clean message (text)" do
      _stdout, stderr, status = run_oneshot("query" => "hi", "output_format" => "xml")
      expect(status).to eq(2)
      expect(stderr).to include("invalid --output-format 'xml'")
    end

    it "still rejects a bogus --output-format even when --json is ALSO given (F10)" do
      stdout, _stderr, status = run_oneshot(
        "query" => "hi", "json" => true, "output_format" => "xml"
      )
      expect(status).to eq(2)
      # --json makes it a machine surface, so the rejection is a #327 envelope
      # on stdout rather than a bare stderr line — parseable, is_error:true.
      env = JSON.parse(stdout)
      expect(env["is_error"]).to be(true)
      expect(env.dig("error", "message")).to include("invalid --output-format 'xml'")
    end

    it "accepts a valid --output-format alongside --json" do
      cmd = described_class.new("query" => "hi", "json" => true, "output_format" => "json")
      expect(cmd.send(:output_format)).to eq(:json)
    end

    it "accepts stream-json and the bare --json alias" do
      expect(described_class.new("query" => "hi", "output_format" => "stream-json")
        .send(:output_format)).to eq(:stream_json)
      expect(described_class.new("query" => "hi", "json" => true)
        .send(:output_format)).to eq(:json)
    end
  end
end
