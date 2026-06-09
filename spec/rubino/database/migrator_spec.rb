# frozen_string_literal: true

RSpec.describe Rubino::Database::Migrator do
  subject(:migrator) { described_class.new(connection) }

  let(:connection) { Rubino::Database::Connection.new(":memory:") }

  describe "#pending?" do
    it "returns true on a fresh database with no migrations applied" do
      expect(migrator.pending?).to be(true)
    end

    it "returns false once all migrations have been applied" do
      migrator.migrate!

      expect(migrator.pending?).to be(false)
    end

    # Regression: the old #up_to_date? returned the NEGATION of its name and a
    # rescue swallowed every error into a healthy "false", so an unreachable DB
    # looked up-to-date. #pending? must let real errors propagate so callers can
    # report a failure instead of a silent false-OK.
    it "propagates errors instead of swallowing them into a misleading result" do
      broken = instance_double(Rubino::Database::Connection)
      allow(broken).to receive(:db).and_raise(Sequel::DatabaseError, "boom")

      expect { described_class.new(broken).pending? }.to raise_error(Sequel::DatabaseError)
    end
  end
end
