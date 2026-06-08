# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rubino::API::Operations::Skills::ToggleOperation do
  before do
    db = with_test_db
    db[:skill_states].delete
  end

  let(:registry)         { instance_double(Rubino::Skills::Registry) }
  let(:state_repository) { Rubino::Skills::StateRepository.new }
  let(:operation)        { described_class.new(registry: registry, state_repository: state_repository) }

  let(:skill) { instance_double(Rubino::Skills::Skill, name: "git", description: "Git ops") }

  it "disables a known skill and persists the state" do
    allow(registry).to receive(:find).with("git").and_return(skill)
    status, body = operation.call(make_request(body: { "enabled" => false }, params: { name: "git" }))
    expect(status).to eq(200)
    expect(body).to eq(name: "git", enabled: false)
    expect(state_repository.enabled?("git")).to be(false)
  end

  it "re-enables a previously disabled skill" do
    allow(registry).to receive(:find).with("git").and_return(skill)
    state_repository.set("git", enabled: false)
    operation.call(make_request(body: { "enabled" => true }, params: { name: "git" }))
    expect(state_repository.enabled?("git")).to be(true)
  end

  it "raises NotFoundError for unknown skills" do
    allow(registry).to receive(:find).with("nope").and_return(nil)
    expect { operation.call(make_request(body: { "enabled" => true }, params: { name: "nope" })) }
      .to raise_error(Rubino::NotFoundError)
  end

  it "raises ValidationError when enabled is missing" do
    allow(registry).to receive(:find).with("git").and_return(skill)
    expect { operation.call(make_request(body: {}, params: { name: "git" })) }
      .to raise_error(Rubino::ValidationError)
  end
end
