# frozen_string_literal: true

require "spec_helper"

# Skills + models surface. Skills uses a stub registry (the real one walks the
# filesystem) wired through pre-instantiated ops; models is stubbed via its
# model_source callable.
RSpec.describe "API contract: skills + models" do
  before { with_test_db }

  let(:registry) { instance_double(Rubino::Skills::Registry) }
  let(:state_repository) { Rubino::Skills::StateRepository.new }

  let(:fake_skill_git) do
    instance_double(Rubino::Skills::Skill, name: "git", description: "Git ops")
  end

  let(:fake_models) do
    Struct.new(:id, :provider, :context_window).then do |s|
      [s.new("openai/gpt-4o", :openai, 128_000), s.new("anthropic/claude", :anthropic, 200_000)]
    end
  end

  def contract_router
    skills_list   = Rubino::API::Operations::Skills::ListOperation.new(registry: registry,
                                                                       state_repository: state_repository)
    skills_toggle = Rubino::API::Operations::Skills::ToggleOperation.new(registry: registry,
                                                                         state_repository: state_repository)
    models_list   = Rubino::API::Operations::Models::ListOperation.new(model_source: -> { fake_models })

    router = Rubino::API::Router.new
    router.get "/v1/skills",       to: ->(req) { skills_list.call(req) }
    router.put "/v1/skills/:name", to: ->(req) { skills_toggle.call(req) }
    router.get "/v1/models",       to: ->(req) { models_list.call(req) }
    router
  end

  describe "GET /v1/skills" do
    it "200 + array of {name, description, enabled}" do
      allow(registry).to receive(:all).and_return([fake_skill_git])
      get_json "/v1/skills"
      expect(last_response.status).to eq(200)
      expect(json_body).to eq([{ "name" => "git", "description" => "Git ops", "enabled" => true }])
    end

    it "200 + empty array when registry has no skills" do
      allow(registry).to receive(:all).and_return([])
      get_json "/v1/skills"
      expect(json_body).to eq([])
    end
  end

  describe "PUT /v1/skills/:name" do
    it "200 + persists the enabled flag" do
      allow(registry).to receive(:find).with("git").and_return(fake_skill_git)
      put "/v1/skills/git", JSON.generate("enabled" => false),
          { "CONTENT_TYPE" => "application/json" }.merge(auth_headers)
      expect(last_response.status).to eq(200)
      expect(json_body).to eq("name" => "git", "enabled" => false)
      expect(state_repository.enabled?("git")).to be(false)
    end

    it "404 when the skill is not registered" do
      allow(registry).to receive(:find).with("ghost").and_return(nil)
      put "/v1/skills/ghost", JSON.generate("enabled" => true),
          { "CONTENT_TYPE" => "application/json" }.merge(auth_headers)
      expect(last_response.status).to eq(404)
    end

    it "422 when :enabled is missing" do
      allow(registry).to receive(:find).with("git").and_return(fake_skill_git)
      put "/v1/skills/git", "{}",
          { "CONTENT_TYPE" => "application/json" }.merge(auth_headers)
      expect(last_response.status).to eq(422)
    end
  end

  describe "GET /v1/models" do
    it "200 + serialized models" do
      get_json "/v1/models"
      expect(last_response.status).to eq(200)
      expect(json_body).to eq([
                                { "id" => "openai/gpt-4o", "provider" => "openai", "context_window" => 128_000 },
                                { "id" => "anthropic/claude", "provider" => "anthropic", "context_window" => 200_000 }
                              ])
    end
  end
end
