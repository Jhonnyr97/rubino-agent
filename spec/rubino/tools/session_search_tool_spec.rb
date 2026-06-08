# frozen_string_literal: true

require "spec_helper"
require "json"

RSpec.describe Rubino::Tools::SessionSearchTool do
  subject(:tool) { described_class.new }

  before { with_test_db }

  let(:repo)  { Rubino::Session::Repository.new }
  let(:store) { Rubino::Session::Store.new }
  let(:session) { repo.create(source: "test") }

  def parse(result)
    JSON.parse(result.is_a?(Hash) ? (result[:output] || result["output"]) : result)
  end

  it "has name 'session_search'" do
    expect(tool.name).to eq("session_search")
  end

  it "has :low risk level" do
    expect(tool.risk_level).to eq(:low)
  end

  it "finds matching messages and highlights the snippet" do
    store.create(session_id: session[:id], role: "user", content: "I love eating pizza on Sunday")
    store.create(session_id: session[:id], role: "user", content: "Nothing relevant here")

    hits = parse(tool.call("query" => "pizza"))
    expect(hits.size).to eq(1)
    expect(hits.first["session_id"]).to eq(session[:id])
    expect(hits.first["snippet"]).to include("<mark>pizza</mark>")
  end

  it "filters by since/until on created_at" do
    old_id = SecureRandom.uuid
    new_id = SecureRandom.uuid
    Rubino.database.db[:messages].insert(
      id: old_id, session_id: session[:id], role: "user",
      content: "ancient pizza", created_at: "2020-01-01T00:00:00Z"
    )
    Rubino.database.db[:messages].insert(
      id: new_id, session_id: session[:id], role: "user",
      content: "fresh pizza", created_at: "2026-06-01T00:00:00Z"
    )

    hits = parse(tool.call("query" => "pizza", "since" => "2026-01-01T00:00:00Z"))
    expect(hits.map { |h| h["message_id"] }).to eq([new_id])

    hits = parse(tool.call("query" => "pizza", "until" => "2021-01-01T00:00:00Z"))
    expect(hits.map { |h| h["message_id"] }).to eq([old_id])
  end

  it "filters by role" do
    store.create(session_id: session[:id], role: "user",      content: "user said pizza")
    store.create(session_id: session[:id], role: "assistant", content: "assistant about pizza")

    hits = parse(tool.call("query" => "pizza", "role" => "assistant"))
    expect(hits.size).to eq(1)
    expect(hits.first["role"]).to eq("assistant")
  end

  it "filters by tool_name" do
    store.create(session_id: session[:id], role: "tool", tool_name: "grep",
                 content: "matched pizza in file")
    store.create(session_id: session[:id], role: "tool", tool_name: "read",
                 content: "pizza recipe contents")

    hits = parse(tool.call("query" => "pizza", "tool" => "grep"))
    expect(hits.size).to eq(1)
    expect(hits.first["role"]).to eq("tool")
  end

  it "respects the limit parameter and caps at MAX_LIMIT" do
    5.times { |i| store.create(session_id: session[:id], role: "user", content: "pizza #{i}") }

    hits = parse(tool.call("query" => "pizza", "limit" => 2))
    expect(hits.size).to eq(2)

    hits = parse(tool.call("query" => "pizza", "limit" => 9999))
    expect(hits.size).to eq(5)
  end

  it "returns an empty array when nothing matches" do
    store.create(session_id: session[:id], role: "user", content: "only kale here")
    expect(parse(tool.call("query" => "pizza"))).to eq([])
  end

  it "rejects an empty query with an error string" do
    expect(tool.call("query" => "")).to match(/required/i)
  end
end
