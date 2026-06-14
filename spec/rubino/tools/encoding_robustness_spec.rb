# frozen_string_literal: true

require "json"

# Encoding-robustness regression suite (RC gate findings F1–F4).
#
# A single stray non-UTF-8 byte (e.g. a Latin-1 `é` = 0xE9 in a legacy/EU
# source comment) used to make rubino blind to a file (read errored, edit
# raised ArgumentError), and sub-cap tool output carrying such a byte broke
# the LLM request at JSON.generate. These specs lock the graceful behaviour.
module EncodingRobustnessHelpers
  def self.included(base)
    base.let(:tmp_dir) { Dir.mktmpdir("encoding_robustness_spec") }
    base.before { Rubino.configuration.set("terminal", "cwd", tmp_dir) }
    base.after do
      Rubino.configuration.set("terminal", "cwd", nil)
      FileUtils.rm_rf(tmp_dir)
    end
  end

  # A mostly-ASCII file with one Latin-1 0xE9 byte (`é`) — no NUL, so the
  # binary detector correctly treats it as text.
  def write_latin1_file(name = "legacy.rb")
    path = File.join(tmp_dir, name)
    File.binwrite(path, "# Caf\xE9 config\nVERSION=\"1.0\"\n")
    path
  end
end

RSpec.describe Rubino::Tools::ReadTool do
  include EncodingRobustnessHelpers

  describe "encoding robustness (F1)" do
    it "reads a text file with a single non-UTF-8 byte instead of erroring" do
      path   = write_latin1_file
      result = described_class.new.call("file_path" => path)

      expect(result).to be_a(Hash)
      output = result[:output]
      expect(output).not_to include("invalid byte sequence")
      expect(output).not_to include("Error reading")
      # The ASCII content around the bad byte survives; the byte degrades to
      # the Unicode replacement char rather than crashing line rendering.
      expect(output).to include("config")
      expect(output).to include('VERSION="1.0"')
    end
  end
end

RSpec.describe Rubino::Tools::EditTool do
  include EncodingRobustnessHelpers

  describe "encoding robustness & read-only files (F1/F4)" do
    it "edits a file with a stray non-UTF-8 byte (no ArgumentError) — F1" do
      path   = write_latin1_file
      result = described_class.new.call(
        "file_path" => path, "old_string" => 'VERSION="1.0"', "new_string" => 'VERSION="2.0"'
      )

      expect(result).to be_a(Hash)
      expect(result[:output]).to include("1 replacement")
      expect(File.read(path, encoding: "UTF-8").scrub).to include('VERSION="2.0"')
    end

    it "returns a clean error (not raw Errno::EACCES) on a read-only file — F4" do
      path = File.join(tmp_dir, "readonly.txt")
      File.write(path, "original\n")
      File.chmod(0o444, path)

      result = nil
      expect do
        result = described_class.new.call(
          "file_path" => path, "old_string" => "original", "new_string" => "changed"
        )
      end.not_to raise_error

      expect(result).to be_a(String)
      expect(result).to include("Error editing")
      expect(result).to include("denied")
    ensure
      File.chmod(0o644, path) if File.exist?(path)
    end
  end
end

RSpec.describe Rubino::Tools::MultiEditTool do
  include EncodingRobustnessHelpers

  describe "encoding robustness (F1)" do
    it "edits a file with a stray non-UTF-8 byte" do
      path   = write_latin1_file
      result = described_class.new.call(
        "file_path" => path,
        "edits" => [{ "old_string" => 'VERSION="1.0"', "new_string" => 'VERSION="2.0"' }]
      )

      msg = result.is_a?(Hash) ? result[:output] : result.to_s
      expect(msg).to include("replacement")
      expect(File.read(path, encoding: "UTF-8").scrub).to include('VERSION="2.0"')
    end
  end
end

RSpec.describe Rubino::Util::Output do
  describe "encoding robustness (F2)" do
    it "scrubs under-cap output so it is JSON-encodable" do
      # Well under both caps — exercises the pass-through branch that used to
      # skip scrubbing and let the bad byte reach JSON.generate.
      raw = +"value: \xE9 end\n"
      expect(raw.valid_encoding?).to be(false)

      out = described_class.truncate(raw, max_bytes: 30_000, max_lines: 2_000)

      expect(out.valid_encoding?).to be(true)
      expect { JSON.generate({ role: "tool", content: out }) }.not_to raise_error
    end

    it "leaves valid sub-cap output untouched" do
      raw = "plain ascii output\n"
      out = described_class.truncate(raw, max_bytes: 30_000, max_lines: 2_000)
      expect(out).to eq(raw)
    end
  end
end

RSpec.describe Rubino::Tools::GrepTool do
  include EncodingRobustnessHelpers

  describe "encoding robustness (F3)" do
    it "returns a clean error on a bad regex pattern instead of raising RegexpError" do
      tool = described_class.new
      # Force the Ruby fallback regardless of host rg availability.
      allow(tool).to receive(:ripgrep_available?).and_return(false)

      result = nil
      expect { result = tool.call("pattern" => "(unclosed", "path" => tmp_dir) }.not_to raise_error
      expect(result).to be_a(String)
      expect(result).to include("invalid regex pattern")
    end
  end
end
