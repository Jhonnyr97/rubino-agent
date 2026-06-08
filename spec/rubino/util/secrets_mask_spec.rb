# frozen_string_literal: true

RSpec.describe Rubino::Util::SecretsMask do
  describe ".sensitive_key?" do
    it "flags exact matches and common variants" do
      %w[password passwd token secret api_key apikey api-key
         access_key bearer authorization auth private_key].each do |k|
        expect(described_class.sensitive_key?(k)).to be(true), "expected #{k.inspect} sensitive"
      end
    end

    it "flags compound names that contain a secret token" do
      expect(described_class.sensitive_key?("github_token")).to be true
      expect(described_class.sensitive_key?("DB_PASSWORD")).to be true
      expect(described_class.sensitive_key?("aws_access_key_id")).to be true
    end

    it "does not flag benign keys" do
      %w[file_path command pattern user count].each do |k|
        expect(described_class.sensitive_key?(k)).to be(false), "expected #{k.inspect} not sensitive"
      end
    end
  end

  describe ".mask_value" do
    it "replaces the value when the key is sensitive" do
      expect(described_class.mask_value("hunter2", key: "password")).to eq("***")
      expect(described_class.mask_value("sk_live_xyz", key: "api_key")).to eq("***")
    end

    it "leaves benign key/value pairs alone" do
      expect(described_class.mask_value("foo.rb", key: "file_path")).to eq("foo.rb")
    end

    it "scans inline patterns when the key is benign" do
      cmd = 'curl -H "Authorization: Bearer sk_live_xyz" https://api'
      masked = described_class.mask_value(cmd, key: "command")
      expect(masked).to include("Authorization: ***")
      expect(masked).not_to include("sk_live_xyz")
    end

    it "is a no-op on nil" do
      expect(described_class.mask_value(nil, key: "password")).to be_nil
    end
  end

  describe ".mask_inline" do
    it "masks key=value patterns" do
      expect(described_class.mask_inline("PASSWORD=foo")).to eq("PASSWORD=***")
      expect(described_class.mask_inline("api_key=abc xyz")).to eq("api_key=*** xyz")
    end

    it "masks key: value patterns (HTTP headers, YAML)" do
      expect(described_class.mask_inline("Authorization: Bearer XYZ")).to eq("Authorization: ***")
      expect(described_class.mask_inline("token: foo")).to eq("token: ***")
    end

    it "preserves the surrounding text" do
      input  = "set TOKEN=sk_abc && run"
      masked = described_class.mask_inline(input)
      expect(masked).to start_with("set TOKEN=*** && run")
    end
  end

  describe ".mask_hash" do
    it "masks sensitive keys and leaves others alone" do
      h = { "file_path" => "foo.rb", "token" => "abc" }
      expect(described_class.mask_hash(h)).to eq("file_path" => "foo.rb", "token" => "***")
    end

    it "does not mutate the input" do
      h = { token: "abc" }
      described_class.mask_hash(h)
      expect(h[:token]).to eq("abc")
    end
  end
end
