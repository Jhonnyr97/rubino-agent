# frozen_string_literal: true

RSpec.describe Rubino::Tools::SummarizeFileTool do
  subject(:tool) do
    described_class.new.tap { |t| t.aux_client = fake_aux }
  end

  # Records every aux prompt and returns a deterministic, tagged response so we
  # can tell MAP calls (per-chunk) from the REDUCE call (combine).
  let(:fake_aux) do
    Class.new do
      attr_reader :prompts

      def initialize = @prompts = []

      def call(task:, messages:)
        @prompts << { task: task, content: messages.first[:content] }
        text = messages.first[:content].start_with?("Combine these partial") ? "COMBINED" : "map#{@prompts.size}"
        Struct.new(:content).new(text)
      end
    end.new
  end
  let(:tmp_dir) { Dir.mktmpdir("summarize_spec") }

  def payload(result) = result.is_a?(Hash) ? result[:output] : result

  # summarize_file is now workspace-sandboxed (r5 MF-1 / NEW-2): it routes raw
  # file bytes through the aux LLM, so an out-of-workspace path must be DENIED
  # rather than summarized. Root the workspace at tmp_dir so the in-tmp fixtures
  # are inside it; the out-of-workspace path gets its own example below.
  before { Rubino.configuration.set("terminal", "cwd", tmp_dir) }

  after do
    Rubino.configuration.set("terminal", "cwd", nil)
    Rubino::Workspace.reset!
    FileUtils.rm_rf(tmp_dir)
  end

  it "has name 'summarize_file' and :low risk (usable by read-only agents)" do
    expect(tool.name).to eq("summarize_file")
    expect(tool.risk_level).to eq(:low)
  end

  it "summarizes a small (single-chunk) file in one map call" do
    path = File.join(tmp_dir, "small.txt")
    File.write(path, "a short document\nwith a few lines\n")

    result = tool.call("file_path" => path)
    expect(payload(result)).to eq("map1")
    expect(fake_aux.prompts.size).to eq(1)
    expect(fake_aux.prompts.first[:task]).to eq("summarize")
  end

  it "map-reduces a multi-chunk file: a map per chunk, then one combine" do
    # Force several chunks by exceeding CHUNK_BYTES.
    big = (("x" * 1000) + "\n") * 80 # ~80KB → 4 chunks of 24KB
    path = File.join(tmp_dir, "big.txt")
    File.write(path, big)

    result = payload(tool.call("file_path" => path))
    map_calls    = fake_aux.prompts.count { |p| !p[:content].start_with?("Combine these partial") }
    reduce_calls = fake_aux.prompts.count { |p| p[:content].start_with?("Combine these partial") }
    expect(map_calls).to be >= 2          # one per chunk
    expect(reduce_calls).to eq(1)         # single combine (summaries fit one chunk)
    expect(result).to eq("COMBINED")
  end

  it "threads `focus` into the summarization prompt" do
    path = File.join(tmp_dir, "f.txt")
    File.write(path, "content\n")
    tool.call("file_path" => path, "focus" => "chapter titles and page numbers")
    expect(fake_aux.prompts.first[:content]).to include("chapter titles and page numbers")
  end

  it "refuses a binary file and tells the model to convert it first" do
    path = File.join(tmp_dir, "b.bin")
    File.binwrite(path, "PDF\x00\x01\x02binary")
    result = tool.call("file_path" => path)
    expect(result).to include("looks binary")
    expect(result).to include("read_attachment")
    expect(fake_aux.prompts).to be_empty
  end

  it "handles an empty file without calling the LLM" do
    path = File.join(tmp_dir, "empty.txt")
    File.write(path, "")
    result = tool.call("file_path" => path)
    expect(result).to include("empty")
    expect(fake_aux.prompts).to be_empty
  end

  it "errors clearly when the file does not exist inside the workspace" do
    expect(payload(tool.call("file_path" => File.join(tmp_dir, "nope.txt")))).to include("File not found")
  end

  # NEW-2 (r5c): summarize_file routes raw bytes through the aux LLM, so an
  # out-of-workspace sibling (or ~/.ssh, sibling-repo secret) must be DENIED
  # with the typed :outside_workspace error — NOT summarized, NOT reported as
  # "doesn't exist". Fails on the pre-fix code, which summarized it.
  it "denies an out-of-workspace file as outside the workspace, not summarized (r5c NEW-2)" do
    Dir.mktmpdir("sibling") do |sibling|
      outside = File.join(sibling, "secret.txt")
      File.write(outside, "sensitive sibling content\n")

      result = tool.call("file_path" => outside)
      expect(result).to be_a(Hash)
      expect(result[:error_code]).to eq(:outside_workspace)
      expect(result[:output]).to include("outside your workspace")
      expect(result[:output]).not_to include("File not found")
      # The bytes never reached the aux LLM.
      expect(fake_aux.prompts).to be_empty
    end
  end

  it "summarizes an out-of-workspace file once its folder is added via /add-dir" do
    Dir.mktmpdir("added") do |added|
      path = File.join(added, "doc.txt")
      File.write(path, "now-allowed content\n")
      Rubino::Workspace.add(added)

      result = tool.call("file_path" => path)
      expect(payload(result)).to eq("map1")
      expect(fake_aux.prompts.size).to eq(1)
    end
  end

  # Agent-internal reads (pastes/attachments under ~/.rubino) must keep working
  # even though that dir sits outside the project workspace.
  it "still summarizes an agent-internal file under the Rubino home" do
    home = Dir.mktmpdir("rubino-home")
    allow(Rubino).to receive(:home_path).and_return(home)
    path = File.join(home, "pastes", "p.txt")
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, "a pasted document\n")

    result = tool.call("file_path" => path)
    expect(payload(result)).to eq("map1")
  ensure
    FileUtils.rm_rf(home)
  end
end
