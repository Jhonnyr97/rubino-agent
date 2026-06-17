# frozen_string_literal: true

require "ostruct"
require "tmpdir"

# Variant B — the deterministic post-turn skill-distillation job. The gate is
# fully deterministic (run succeeded AND >= TOOL_THRESHOLD tool calls AND not
# already covered); only on a gate-PASS does it spend exactly ONE auxiliary-LLM
# call to distil the transcript into a SKILL.md. These specs never hit a real
# model — the aux call is mocked.
RSpec.describe Rubino::Jobs::Handlers::DistillSkillJob do
  subject(:job) { described_class.new }

  let(:db_connection) { test_database }
  let(:db) { db_connection.db }
  let(:aux_client) { instance_double(Rubino::LLM::AuxiliaryClient) }

  # SK-1: distilled skills are written under the agent HOME skills dir, NOT the
  # cwd-relative skills.paths. @home is the resolved home; @skills_dir is its
  # skills/ subdir — where distill writes and the registry discovers.
  around do |example|
    Dir.mktmpdir do |home|
      @home = home
      @skills_dir = File.join(home, "skills")
      FileUtils.mkdir_p(@skills_dir)
      Rubino::Metrics.reset!
      example.run
      Rubino::Metrics.reset!
    end
  end

  before do
    allow(Rubino).to receive(:database).and_return(db_connection)
    # skills.paths points elsewhere (the legacy cwd-relative default) to prove
    # distill ignores it and writes to the home dir resolved below.
    allow(Rubino).to receive(:configuration).and_return(
      test_configuration("skills" => { "paths" => ["~/.rubino/skills"] })
    )
    allow(Rubino::Config::Loader).to receive(:default_home_path).and_return(@home)
    allow(Rubino::LLM::AuxiliaryClient).to receive(:new).and_return(aux_client)
  end

  def seed_session(id = "s1")
    now = Time.now.utc.iso8601
    db[:sessions].insert(id: id, source: "test", status: "active",
                         message_count: 0, token_count: 0, created_at: now, updated_at: now)
    id
  end

  def add_message(session_id, role, content, tool_name: nil)
    Rubino::Session::Store.new(db: db).create(
      session_id: session_id, role: role, content: content, tool_name: tool_name
    )
  end

  # A worthy run: user task + >= 5 tool calls + a non-empty final answer.
  def seed_worthy_run(session_id)
    add_message(session_id, "user", "Add a POST /reports endpoint to the Sinatra app with validation")
    6.times { |i| add_message(session_id, "tool", "ran step #{i}", tool_name: "bash") }
    add_message(session_id, "assistant", "Done — the endpoint is wired up and tested.")
  end

  # A trivial run: 1 tool call, below the threshold.
  def seed_trivial_run(session_id)
    add_message(session_id, "user", "what time is it")
    add_message(session_id, "tool", "12:00", tool_name: "bash")
    add_message(session_id, "assistant", "It's noon.")
  end

  def stub_distill(json)
    allow(aux_client).to receive(:call).and_return(OpenStruct.new(content: json))
  end

  def good_candidate_json
    JSON.dump(
      "create" => true,
      "name" => "add-sinatra-post-endpoint",
      "description" => "Add a validated POST endpoint to a Sinatra app — when adding write routes.",
      "body" => "# Add a Sinatra POST endpoint\n\n1. Define `post '/path'`.\n2. Validate params.\n3. Return JSON."
    )
  end

  describe "the deterministic gate" do
    it "FIRES on a worthy/complex run: spends one aux call and writes a valid SKILL.md" do
      sid = seed_session
      seed_worthy_run(sid)
      stub_distill(good_candidate_json)

      job.perform(session_id: sid)

      expect(aux_client).to have_received(:call).once
      path = File.join(@skills_dir, "add-sinatra-post-endpoint", "SKILL.md")
      expect(File).to exist(path)

      content = File.read(path)
      expect(content).to start_with("---\n")
      fm = YAML.safe_load(content.split("---\n")[1])
      expect(fm["name"]).to eq("add-sinatra-post-endpoint")
      expect(fm["description"]).to include("Sinatra")
      expect(content).to include("# Add a Sinatra POST endpoint")

      expect(Rubino::Metrics.render).to match(/^skills_created_total(\{\})? 1$/)
    end

    # SK-1: a distill that fires while cwd is inside a repo must NOT drop a
    # SKILL.md into the repo working tree — it writes to the agent HOME.
    it "writes under the agent HOME, not the cwd repo, when distilling" do
      sid = seed_session
      seed_worthy_run(sid)
      stub_distill(good_candidate_json)

      Dir.mktmpdir do |repo|
        Dir.chdir(repo) { job.perform(session_id: sid) }
        expect(Dir.glob(File.join(repo, "**", "SKILL.md"))).to be_empty
        expect(File).not_to exist(File.join(repo, ".rubino"))
      end
      expect(File).to exist(File.join(@skills_dir, "add-sinatra-post-endpoint", "SKILL.md"))
    end

    it "does NOT fire on a trivial run: no aux call, no skill written" do
      sid = seed_session
      seed_trivial_run(sid)
      allow(aux_client).to receive(:call)

      job.perform(session_id: sid)

      expect(aux_client).not_to have_received(:call)
      expect(Dir.children(@skills_dir)).to be_empty
      expect(Rubino::Metrics.render).not_to match(/^skills_created_total/)
    end

    it "does NOT fire when the run did not succeed (no non-empty final answer)" do
      sid = seed_session
      add_message(sid, "user", "do a big multi-step thing")
      6.times { |i| add_message(sid, "tool", "step #{i}", tool_name: "bash") }
      # no assistant answer -> not succeeded
      allow(aux_client).to receive(:call)

      job.perform(session_id: sid)

      expect(aux_client).not_to have_received(:call)
      expect(Dir.children(@skills_dir)).to be_empty
    end

    it "respects RA_DISTILL_TOOL_THRESHOLD as the configurable bound" do
      expect(described_class::TOOL_THRESHOLD).to eq(5)
    end
  end

  describe "when the aux model declines (gate passed but not skill-worthy)" do
    it "writes nothing and does not count a creation" do
      sid = seed_session
      seed_worthy_run(sid)
      stub_distill(JSON.dump("create" => false, "reason" => "one-off"))

      job.perform(session_id: sid)

      expect(aux_client).to have_received(:call).once
      expect(Dir.children(@skills_dir)).to be_empty
      expect(Rubino::Metrics.render).not_to match(/^skills_created_total/)
    end
  end

  # Regression for #368: already_covered? used to return true on ANY single
  # 4+-char word shared with a built-in skill's name/description — so the word
  # "rails" sitting in ruby-expert's description suppressed an unrelated
  # deploy-workflow task. Coverage now requires MEANINGFUL overlap (a name-level
  # match or multiple salient stopword-filtered tokens past a Jaccard floor), so
  # a lone common word can no longer gate a distinct task off.
  describe "coverage gate is not tripped by a single shared word (#368)" do
    def fake_skill(name, description)
      instance_double(Rubino::Skills::Skill, name: name, description: description)
    end

    def stub_registry(skills)
      registry = instance_double(Rubino::Skills::Registry, all: skills)
      allow(Rubino::Skills::Registry).to receive(:new).and_return(registry)
      allow(registry).to receive(:find).and_return(nil)
    end

    def seed_task(session_id, task)
      add_message(session_id, "user", task)
      6.times { |i| add_message(session_id, "tool", "step #{i}", tool_name: "bash") }
      add_message(session_id, "assistant", "Done.")
    end

    let(:ruby_expert) do
      fake_skill("ruby-expert",
                 "Expert in Ruby, Rails, RSpec, ActiveRecord and idiomatic Ruby code.")
    end

    it "does NOT suppress 'deploy workflow for Rails' just because ruby-expert mentions Rails" do
      sid = seed_session
      seed_task(sid, "Add a deploy workflow for Rails to staging via Capistrano")
      stub_registry([ruby_expert])
      stub_distill(good_candidate_json)

      job.perform(session_id: sid)

      # Gate PASSED: the aux call ran and a skill was written (not suppressed).
      expect(aux_client).to have_received(:call).once
      expect(Dir.children(@skills_dir)).not_to be_empty
    end

    it "DOES suppress a genuinely duplicate task (name-level match)" do
      sid = seed_session
      seed_task(sid, "Add a validated POST endpoint to my Sinatra app for write routes")
      stub_registry([
                      fake_skill("add-sinatra-post-endpoint",
                                 "Add a validated POST endpoint to a Sinatra app — when adding write routes.")
                    ])
      allow(aux_client).to receive(:call)

      job.perform(session_id: sid)

      # Gate SUPPRESSED: no aux call, no skill written — the work is already covered.
      expect(aux_client).not_to have_received(:call)
      expect(Dir.children(@skills_dir)).to be_empty
    end
  end

  describe "robustness" do
    it "is a no-op without a session_id" do
      expect { job.perform({}) }.not_to raise_error
    end

    it "rejects a candidate with an invalid (non-kebab) name" do
      sid = seed_session
      seed_worthy_run(sid)
      stub_distill(JSON.dump(
                     "create" => true, "name" => "Not Valid Name",
                     "description" => "x", "body" => "# y\n"
                   ))

      job.perform(session_id: sid)
      expect(Dir.children(@skills_dir)).to be_empty
    end

    it "registers itself as a runnable job handler" do
      expect(Rubino::Jobs::Registry.handler_for("DistillSkillJob")).to eq(described_class)
    end
  end

  # Regression guard (PR #135): the job used to be enqueued on every turn and,
  # when run inline against an unconfigured/exhausted aux model, retried with
  # exponential backoff — leaving lingering work that polluted later specs
  # ("zombie run"). The job must make EXACTLY ONE aux call and leave NO surviving
  # thread or unfinished job behind.
  describe "leaves no lingering thread or job (the zombie-run regression)" do
    it "spawns no surviving thread and makes exactly one aux call on a gate-pass" do
      sid = seed_session
      seed_worthy_run(sid)
      stub_distill(good_candidate_json)

      before_threads = Thread.list.size
      job.perform(session_id: sid)

      expect(aux_client).to have_received(:call).once
      expect(Thread.list.size).to eq(before_threads)
    end

    it "runs cleanly end-to-end through the inline runner and leaves no running job" do
      sid = seed_session
      seed_worthy_run(sid)
      stub_distill(good_candidate_json)

      before_threads = Thread.list.size
      job_id = Rubino::Jobs::Queue.new(db: db).enqueue(
        "DistillSkillJob", { session_id: sid }
      )
      Rubino::Jobs::Runner.new(db: db).run_job(job_id)

      # Inline runner ran it to completion: no queued/running residue, no thread.
      row = db[:jobs].where(id: job_id).first
      expect(row[:status]).to eq("completed")
      expect(db[:jobs].where(status: %w[queued running]).count).to eq(0)
      expect(Thread.list.size).to eq(before_threads)
      expect(aux_client).to have_received(:call).once
    end

    it "is gated off by skills.auto_distill=false (mirrors memory.auto_extract)" do
      cfg = test_configuration(
        "skills" => { "paths" => [@skills_dir], "auto_distill" => false }
      )
      expect(cfg.skills_auto_distill?).to be(false)
    end

    it "defaults skills.auto_distill on when skills are enabled" do
      cfg = test_configuration("skills" => { "paths" => [@skills_dir] })
      expect(cfg.skills_auto_distill?).to be(true)
    end
  end
end
