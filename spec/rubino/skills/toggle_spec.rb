# frozen_string_literal: true

# The ONE enable/disable write path every surface shares (#188): the HTTP API
# toggle, the in-chat /skills enable|disable, and the `rubino skills` CLI
# verbs. Registry-validated; nothing is written for an unknown name.
RSpec.describe Rubino::Skills::Toggle do
  let(:registry)         { instance_double(Rubino::Skills::Registry) }
  let(:state_repository) { Rubino::Skills::StateRepository.new }
  let(:skill)            { instance_double(Rubino::Skills::Skill, name: "git") }

  before { with_test_db }

  it "persists the flag and returns the skill for a registered name" do
    allow(registry).to receive(:find).with("git").and_return(skill)

    result = described_class.set("git", enabled: false,
                                        registry: registry, state_repository: state_repository)

    expect(result).to eq(skill)
    expect(state_repository.enabled?("git")).to be(false)
  end

  it "returns nil and writes nothing for an unknown name" do
    allow(registry).to receive(:find).with("nope").and_return(nil)

    result = described_class.set("nope", enabled: false,
                                         registry: registry, state_repository: state_repository)

    expect(result).to be_nil
    expect(Rubino.database.db[:skill_states].count).to eq(0)
  end

  it "re-enables a previously disabled skill" do
    allow(registry).to receive(:find).with("git").and_return(skill)
    state_repository.set("git", enabled: false)

    described_class.set("git", enabled: true,
                               registry: registry, state_repository: state_repository)

    expect(state_repository.enabled?("git")).to be(true)
  end
end
