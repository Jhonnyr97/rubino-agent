# frozen_string_literal: true

# Covers the `/jobs` slash command (#187) — the in-chat window into the
# PERSISTENT jobs queue (the one the agent feeds mid-session), distinct from
# the in-process /agents subagents. List shares the CLI's table rendering
# (CLI::JobsCommand.render_list); detail resolves short-id prefixes.
RSpec.describe Rubino::Commands::Executor do
  subject(:exec) { described_class.new(loader: loader, ui: ui) }

  let(:ui)     { Rubino::UI::Null.new }
  let(:loader) { Rubino::Commands::Loader.new(config: test_configuration) }
  let(:config) do
    test_configuration("jobs" => { "mode" => "manual", "max_attempts" => 3 })
  end
  let(:queue) { Rubino::Jobs::Queue.new(config: config) }

  before do
    with_test_db
    allow(Rubino).to receive(:configuration).and_return(config)
  end

  def info_lines
    ui.messages.select { |m| m[:level] == :info }.map { |m| m[:message].to_s }
  end

  describe "/jobs (list)" do
    it "explains the empty queue instead of rendering a bare table" do
      result = exec.try_execute("/jobs")

      expect(result).to eq(:handled)
      expect(info_lines.join("\n")).to include("No jobs yet")
    end

    it "renders the status counts plus the same table as `rubino jobs list`" do
      queue.enqueue("DistillSkillJob", { "session_id" => "s1" })
      queue.enqueue("ExtractMemoryJob", { "session_id" => "s2" })
      failed_id = queue.enqueue("ExtractMemoryJob", { "session_id" => "s3" })
      Rubino.database.db[:jobs].where(id: failed_id).update(status: "failed")

      exec.try_execute("/jobs")

      expect(info_lines.join("\n")).to include("2 queued", "1 failed")
      table = ui.messages.find { |m| m[:level] == :table }
      expect(table[:message][:headers]).to eq(%w[ID Type Status Attempts RunAt])
      expect(table[:message][:rows].length).to eq(3)
    end
  end

  describe "/jobs <id> (detail)" do
    it "shows one job in full by short-id prefix, including its error" do
      id = queue.enqueue("DistillSkillJob", { "session_id" => "s1" })
      Rubino.database.db[:jobs].where(id: id).update(status: "failed", last_error: "boom went the model")

      result = exec.try_execute("/jobs #{id[0..7]}")

      expect(result).to eq(:handled)
      lines = info_lines.join("\n")
      expect(lines).to include("DistillSkillJob", "failed", "attempts", "session_id")
      err = ui.messages.find { |m| m[:level] == :error }
      expect(err[:message]).to include("boom went the model")
    end

    it "errors on an unknown id with a pointer back to the list" do
      exec.try_execute("/jobs deadbeef")

      err = ui.messages.find { |m| m[:level] == :error }
      expect(err[:message]).to include("no job with id deadbeef")
      expect(info_lines.join("\n")).to include("List them with /jobs")
    end
  end
end
