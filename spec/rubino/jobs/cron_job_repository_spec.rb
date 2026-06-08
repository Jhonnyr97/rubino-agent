# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rubino::Jobs::CronJobRepository do
  before do
    db = with_test_db
    db[:cron_jobs].delete
  end

  let(:repo) { described_class.new }

  it "creates a job with defaults" do
    job = repo.create(name: "morning", schedule: "0 9 * * *", prompt: "summarize")
    expect(job[:name]).to eq("morning")
    expect(job[:deliver]).to eq("local")
    expect(job[:enabled]).to be(true)
  end

  it "lists jobs and filters by enabled" do
    repo.create(name: "a", schedule: "* * * * *", prompt: "x", enabled: true)
    repo.create(name: "b", schedule: "* * * * *", prompt: "y", enabled: false)
    expect(repo.list(include_disabled: true).map { |j| j[:name] }).to contain_exactly("a", "b")
    expect(repo.list(include_disabled: false).map { |j| j[:name] }).to eq(["a"])
  end

  it "updates an existing job" do
    job = repo.create(name: "a", schedule: "* * * * *", prompt: "x")
    updated = repo.update(job[:id], name: "renamed", enabled: false)
    expect(updated[:name]).to eq("renamed")
    expect(updated[:enabled]).to be(false)
  end

  it "encodes a :skills array into skills_json on update" do
    job = repo.create(name: "a", schedule: "* * * * *", prompt: "x", skills: %w[foo])
    updated = repo.update(job[:id], skills: %w[bar baz])
    expect(JSON.parse(updated[:skills_json])).to eq(%w[bar baz])
  end

  it "records the latest run" do
    job = repo.create(name: "a", schedule: "* * * * *", prompt: "x")
    repo.record_run(job[:id], run_id: "run-1")
    fresh = repo.find(job[:id])
    expect(fresh[:last_run_id]).to eq("run-1")
    expect(fresh[:last_run_at]).not_to be_nil
  end

  it "destroys a job" do
    job = repo.create(name: "a", schedule: "* * * * *", prompt: "x")
    repo.destroy!(job[:id])
    expect(repo.find(job[:id])).to be_nil
  end
end
