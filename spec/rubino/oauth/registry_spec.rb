# frozen_string_literal: true

require "spec_helper"

RSpec.describe Rubino::OAuth::Registry do
  before { described_class.reset! }
  after  { described_class.reset! }

  let(:dummy_provider) do
    Class.new(Rubino::OAuth::Provider) do
      def self.id            = :dummy
      def self.display_name  = "Dummy"
      def self.site          = "https://dummy.test"
      def self.authorize_path = "/auth"
      def self.token_path    = "/token"
      def fetch_account_info(_token); { account_id: "1" }; end
    end
  end

  it "registers and fetches providers" do
    instance = dummy_provider.new(client_id: "id", client_secret: "secret")
    described_class.register(:dummy, instance)
    expect(described_class.fetch(:dummy)).to be(instance)
    expect(described_class.ids).to eq([:dummy])
  end

  it "raises NotFoundError on unknown id" do
    expect { described_class.fetch(:nope) }.to raise_error(Rubino::NotFoundError)
  end

  describe ".load_from_config!" do
    let(:configuration) { instance_double(Rubino::Config::Configuration) }

    it "loads built-in providers declared in config and ignores unknown ids" do
      allow(configuration).to receive(:dig).with("oauth", "providers").and_return(
        "github" => { "client_id" => "gh-id", "client_secret" => "gh-secret", "scopes" => ["repo"] },
        "mystery" => { "client_id" => "x", "client_secret" => "y" }
      )
      described_class.load_from_config!(configuration)
      expect(described_class.ids).to eq([:github])
      expect(described_class.fetch(:github).scopes).to eq(["repo"])
    end

    it "skips providers without credentials" do
      allow(configuration).to receive(:dig).with("oauth", "providers").and_return(
        "github" => { "scopes" => ["repo"] }
      )
      described_class.load_from_config!(configuration)
      expect(described_class.ids).to be_empty
    end
  end
end
