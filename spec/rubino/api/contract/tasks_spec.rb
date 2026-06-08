# frozen_string_literal: true

require "spec_helper"

# Background-subagent (`task`) surface on the HTTP boundary. Drives a fresh
# BackgroundTasks registry seeded through its own reserve/attach/complete API so
# the list/show/stop contracts are proven against the real registry the `task`
# tool writes to.
RSpec.describe "API contract: tasks" do
  before { with_test_db }

  let(:registry) { Rubino::Tools::BackgroundTasks.new }

  def contract_router
    index = Rubino::API::Operations::Tasks::IndexOperation.new(registry: registry)
    show  = Rubino::API::Operations::Tasks::ShowOperation.new(registry: registry)
    stop  = Rubino::API::Operations::Tasks::StopOperation.new(registry: registry)

    router = Rubino::API::Router.new
    router.get  "/v1/tasks",          to: ->(req) { index.call(req) }
    router.get  "/v1/tasks/:id",      to: ->(req) { show.call(req) }
    router.post "/v1/tasks/:id/stop", to: ->(req) { stop.call(req) }
    router
  end

  # Reserves a running entry; pass a runner double to exercise the cancel path.
  def reserve(subagent: "explore", prompt: "find the bug", runner: nil)
    entry = registry.reserve(subagent: subagent, prompt: prompt)
    registry.attach(entry, thread: nil, runner: runner) if runner
    entry
  end

  describe "GET /v1/tasks" do
    it "200 + summary rows newest first" do
      reserve(prompt: "first")
      reserve(prompt: "second")
      get_json "/v1/tasks"
      expect(last_response.status).to eq(200)
      tasks = json_body.fetch("tasks")
      expect(tasks.map { |t| t["prompt"] }).to eq(%w[second first])
      expect(tasks.first.keys).to include(
        "id", "subagent", "prompt", "status", "started_at", "elapsed_seconds", "result_summary"
      )
    end

    it "truncates long results into result_summary" do
      entry = reserve
      registry.complete(entry, status: :completed, result: "x" * 500)
      get_json "/v1/tasks"
      summary = json_body.fetch("tasks").first.fetch("result_summary")
      expect(summary.length).to be <= 201
      expect(summary).to end_with("…")
    end
  end

  describe "GET /v1/tasks/:id" do
    it "200 + full detail with result" do
      entry = reserve
      registry.complete(entry, status: :completed, result: "the full answer")
      get_json "/v1/tasks/#{entry.id}"
      expect(last_response.status).to eq(200)
      expect(json_body).to include("status" => "completed", "result" => "the full answer")
      expect(json_body).to have_key("finished_at")
    end

    it "200 + surfaces the error for a failed task" do
      entry = reserve
      registry.complete(entry, status: :failed, error: "boom")
      get_json "/v1/tasks/#{entry.id}"
      expect(json_body).to include("status" => "failed", "error" => "boom")
    end

    it "404 when the task does not exist" do
      get_json "/v1/tasks/sa_missing"
      expect(last_response.status).to eq(404)
      expect(json_body.dig("error", "code")).to eq("not_found")
    end
  end

  describe "POST /v1/tasks/:id/stop" do
    it "202 + flips the child runner's cancel token" do
      runner = instance_double(Rubino::Agent::Runner)
      expect(runner).to receive(:cancel!)
      entry = reserve(runner: runner)

      post_json "/v1/tasks/#{entry.id}/stop", {}
      expect(last_response.status).to eq(202)
      # Cancellation is async: the snapshot still reads running until the worker
      # unwinds and records its terminal state.
      expect(json_body["status"]).to eq("running")
    end

    it "transitions to cancelled once the worker records terminal state" do
      runner = instance_double(Rubino::Agent::Runner, cancel!: nil)
      entry = reserve(runner: runner)

      post_json "/v1/tasks/#{entry.id}/stop", {}
      registry.complete(entry, status: :cancelled)

      get_json "/v1/tasks/#{entry.id}"
      expect(json_body["status"]).to eq("cancelled")
    end

    it "409 when the task already finished" do
      entry = reserve
      registry.complete(entry, status: :completed, result: "done")
      post_json "/v1/tasks/#{entry.id}/stop", {}
      expect(last_response.status).to eq(409)
      expect(json_body.dig("error", "code")).to eq("conflict")
    end

    it "404 when the task does not exist" do
      post_json "/v1/tasks/sa_missing/stop", {}
      expect(last_response.status).to eq(404)
    end
  end
end
