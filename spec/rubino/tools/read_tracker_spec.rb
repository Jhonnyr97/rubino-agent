# frozen_string_literal: true

# ReadTracker is the per-turn record that lets Edit / MultiEdit refuse to
# write to a file the model never opened, and warn when the file changed
# under their feet between read and edit.
RSpec.describe Rubino::Tools::ReadTracker do
  subject(:tracker) { described_class.new }

  let(:tmp_dir) { Dir.mktmpdir("read-tracker") }

  after { FileUtils.rm_rf(tmp_dir) }

  def write_file(name, content = "x")
    path = File.join(tmp_dir, name)
    File.write(path, content)
    path
  end

  it "is empty on construction" do
    expect(tracker.seen?(write_file("a.txt"))).to be(false)
  end

  it "records a read and returns its stashed mtime" do
    path = write_file("a.txt")
    mtime = File.mtime(path)
    tracker.register(path, mtime)
    expect(tracker.seen?(path)).to be(true)
    expect(tracker.mtime_at_read(path)).to eq(mtime)
  end

  it "canonicalizes paths so a read via relative path matches an edit via absolute path" do
    Dir.chdir(tmp_dir) do
      path = write_file("a.txt")
      tracker.register("./a.txt", File.mtime(path))
      expect(tracker.seen?(path)).to be(true)
    end
  end

  it "resolves symlinks: read via the link and read via the target are the same entry" do
    real = write_file("real.txt")
    link = File.join(tmp_dir, "link.txt")
    File.symlink(real, link)
    tracker.register(link, File.mtime(link))
    expect(tracker.seen?(real)).to be(true)
  end

  it "returns nil mtime for paths it never saw" do
    expect(tracker.mtime_at_read(write_file("a.txt"))).to be_nil
  end

  it "tolerates nil / empty paths without raising" do
    expect { tracker.register(nil, Time.now) }.not_to raise_error
    expect(tracker.seen?(nil)).to be(false)
    expect(tracker.seen?("")).to be(false)
  end
end
