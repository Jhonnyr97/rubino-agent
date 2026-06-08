# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rubino::API::Operations::Skills::ListOperation do
  before do
    db = with_test_db
    db[:skill_states].delete
  end

  let(:registry)         { instance_double(Rubino::Skills::Registry) }
  let(:state_repository) { Rubino::Skills::StateRepository.new }
  let(:operation)        { described_class.new(registry: registry, state_repository: state_repository) }

  def fake_skill(name, description)
    instance_double(Rubino::Skills::Skill, name: name, description: description)
  end

  it "returns skills with default enabled=true" do
    allow(registry).to receive(:all).and_return([fake_skill("git", "Git ops"), fake_skill("ruby", "Ruby exec")])
    status, body = operation.call(make_request)
    expect(status).to eq(200)
    expect(body).to eq([
      { name: "git",  description: "Git ops",   enabled: true },
      { name: "ruby", description: "Ruby exec", enabled: true }
    ])
  end

  it "reflects stored state overrides" do
    allow(registry).to receive(:all).and_return([fake_skill("git", "Git ops")])
    state_repository.set("git", enabled: false)
    _, body = operation.call(make_request)
    expect(body.first[:enabled]).to be(false)
  end
end
