# frozen_string_literal: true

RSpec.describe Rubino::Tools::EditTool do
  subject(:tool) { described_class.new }

  let(:tmp_dir) { Dir.mktmpdir("edit_tool_spec") }

  before { Rubino.configuration.set("terminal", "cwd", tmp_dir) }

  after do
    Rubino.configuration.set("terminal", "cwd", nil)
    FileUtils.rm_rf(tmp_dir)
  end

  def write_file(name, content)
    path = File.join(tmp_dir, name)
    File.write(path, content)
    path
  end

  it "has name 'edit'" do
    expect(tool.name).to eq("edit")
  end

  it "reports medium risk" do
    expect(tool.risk_level).to eq(:medium)
  end

  describe "successful replacement" do
    it "replaces the first occurrence of old_string with new_string" do
      path = write_file("test.rb", "def foo\n  1\nend\n")
      tool.call("file_path" => path, "old_string" => "1", "new_string" => "2")
      expect(File.read(path)).to include("2")
      expect(File.read(path)).not_to include("  1\n")
    end

    it "returns a confirmation message with replacement count" do
      path = write_file("a.txt", "hello world")
      result = tool.call("file_path" => path, "old_string" => "world", "new_string" => "ruby")
      expect(result[:output]).to include("1 replacement")
    end

    it "reports `N replacements · +A −R` metric for the done header" do
      path = write_file("a.txt", "hello world")
      result = tool.call("file_path" => path, "old_string" => "world", "new_string" => "ruby")
      expect(result[:metrics]).to eq("1 replacement · +1 −1")
    end

    it "replaces all occurrences when replace_all is true" do
      path = write_file("b.txt", "a a a")
      result = tool.call("file_path" => path, "old_string" => "a", "new_string" => "b", "replace_all" => true)
      expect(File.read(path)).to eq("b b b")
      expect(result[:output]).to include("3 replacement")
    end
  end

  describe "error cases" do
    it "returns error when file does not exist" do
      result = tool.call("file_path" => "/no/such/file.rb", "old_string" => "x", "new_string" => "y")
      expect(result).to include("Error")
    end

    it "returns error when old_string is not found in file" do
      path = write_file("c.txt", "hello")
      result = tool.call("file_path" => path, "old_string" => "not_here", "new_string" => "x")
      expect(result).to include("not found")
    end

    it "returns error when multiple matches exist and replace_all is false" do
      path = write_file("d.txt", "x x x")
      result = tool.call("file_path" => path, "old_string" => "x", "new_string" => "y")
      expect(result).to include("3 matches")
    end
  end
end
