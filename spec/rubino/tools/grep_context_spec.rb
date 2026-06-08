# frozen_string_literal: true

# Grep -A/-B/-C context lines. Exercises the Ruby fallback path so the
# behavior is portable; the ripgrep path is just a passthrough to rg's own
# -A/-B/-C flags, which we trust. We force the fallback by stubbing
# ripgrep_available? to false.
RSpec.describe Rubino::Tools::GrepTool do
  subject(:tool) { described_class.new }

  let(:tmp_dir) { Dir.mktmpdir("grep-context") }

  before { allow(tool).to receive(:ripgrep_available?).and_return(false) }

  after { FileUtils.rm_rf(tmp_dir) }

  def write_file(name, content)
    path = File.join(tmp_dir, name)
    File.write(path, content)
    path
  end

  describe "after (-A) context" do
    it "emits N lines after each match prefixed with -" do
      write_file("a.txt", "ignored\nMATCH here\ntail1\ntail2\ntail3\nignored\n")
      out = tool.call("pattern" => "MATCH", "path" => tmp_dir, "after" => 2)
      body = out[:output]
      expect(body).to match(/a\.txt:2:\s+MATCH here/)
      expect(body).to match(/a\.txt:3-\s+tail1/)
      expect(body).to match(/a\.txt:4-\s+tail2/)
      expect(body).not_to match(/tail3/)
    end
  end

  describe "before (-B) context" do
    it "emits N lines before each match prefixed with -" do
      write_file("b.txt", "lead1\nlead2\nlead3\nMATCH here\ntail\n")
      out = tool.call("pattern" => "MATCH", "path" => tmp_dir, "before" => 2)
      body = out[:output]
      expect(body).to match(/b\.txt:2-\s+lead2/)
      expect(body).to match(/b\.txt:3-\s+lead3/)
      expect(body).to match(/b\.txt:4:\s+MATCH here/)
      expect(body).not_to match(/lead1/)
    end
  end

  describe "context (-C) symmetric" do
    it "wins over before/after when both are passed" do
      write_file("c.txt", "l1\nl2\nl3\nMATCH\nt1\nt2\nt3\n")
      out = tool.call("pattern" => "MATCH", "path" => tmp_dir,
                      "context" => 1, "before" => 5, "after" => 5)
      body = out[:output]
      expect(body).to match(/c\.txt:3-\s+l3/)
      expect(body).to match(/c\.txt:4:\s+MATCH/)
      expect(body).to match(/c\.txt:5-\s+t1/)
      expect(body).not_to match(/l1/) # `context` of 1 wins, so we don't see line 1 or 2
      expect(body).not_to match(/t3/)
    end
  end

  describe "no context (default)" do
    it "behaves exactly like before — only the match line" do
      write_file("d.txt", "before\nMATCH\nafter\n")
      out = tool.call("pattern" => "MATCH", "path" => tmp_dir)
      body = out[:output]
      expect(body).to match(/d\.txt:2:\s+MATCH/)
      expect(body).not_to match(/before/)
      expect(body).not_to match(/after/)
    end
  end
end
