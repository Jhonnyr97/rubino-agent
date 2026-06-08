# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rubino::API::Operations::Runs::CreateOperation do
  before { with_test_db }
  let(:session_repo) { Rubino::Session::Repository.new }
  let(:run_repo)     { Rubino::Run::Repository.new }
  let(:executor)     { instance_double(Rubino::Run::Executor, start: nil) }
  let(:operation)    { described_class.new(session_repository: session_repo, run_repository: run_repo, executor: executor) }

  it "creates a run and dispatches it" do
    session = session_repo.create(source: "api")
    status, body = operation.call(make_request(body: { "input" => "hello" }, params: { id: session[:id] }))

    expect(status).to eq(201)
    expect(body[:session_id]).to eq(session[:id])
    expect(body[:status]).to eq("running")
    expect(executor).to have_received(:start)
    expect(run_repo.find(body[:id])).not_to be_nil
  end

  it "raises NotFoundError when the session does not exist" do
    expect { operation.call(make_request(body: { "input" => "x" }, params: { id: "no" })) }
      .to raise_error(Rubino::NotFoundError)
  end

  it "raises ValidationError when input is missing" do
    session = session_repo.create(source: "api")
    expect { operation.call(make_request(body: {}, params: { id: session[:id] })) }
      .to raise_error(Rubino::ValidationError)
  end

  it "raises ValidationError when input is blank and there are no attachments" do
    session = session_repo.create(source: "api")
    expect { operation.call(make_request(body: { "input" => "   " }, params: { id: session[:id] })) }
      .to raise_error(Rubino::ValidationError) { |e| expect(e.details[:errors]).to eq(input: ["must be filled"]) }
  end

  it "accepts an image-only run: blank input with attachments" do
    session = session_repo.create(source: "api")
    status, body = operation.call(
      make_request(body: { "input" => "", "attachments" => ["https://example.test/cat.png"] }, params: { id: session[:id] })
    )

    expect(status).to eq(201)
    expect(executor).to have_received(:start)
    expect(run_repo.find(body[:id])).not_to be_nil
  end

  it "accepts attachments with no input key at all" do
    session = session_repo.create(source: "api")
    status, = operation.call(
      make_request(body: { "attachments" => ["https://example.test/cat.png"] }, params: { id: session[:id] })
    )

    expect(status).to eq(201)
    expect(executor).to have_received(:start)
  end
end
