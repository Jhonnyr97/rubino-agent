# frozen_string_literal: true

require "sequel"
require "sequel/extensions/migration"

module Rubino
  module Database
    # Handles database schema migrations in order.
    # Migrations are stored as numbered Sequel migration files.
    class Migrator
      MIGRATIONS_PATH = File.expand_path("migrations", __dir__)

      def initialize(connection)
        @connection = connection
      end

      # Runs all pending migrations
      def migrate!
        Sequel::Migrator.run(@connection.db, MIGRATIONS_PATH)
      end

      # Returns current migration version
      def current_version
        Sequel::Migrator.get_current_migration_version(@connection.db)
      rescue StandardError
        0
      end

      # Returns true if there are unapplied migrations.
      #
      # Intentionally does NOT rescue: a connection/schema error here is a real
      # health problem and must propagate so callers (e.g. doctor) can report a
      # failure instead of silently treating an unreachable DB as "up to date".
      def pending?
        !Sequel::Migrator.is_current?(@connection.db, MIGRATIONS_PATH)
      end

      # Returns list of pending migration files
      def pending_migrations
        Sequel::Migrator.migrator_class(MIGRATIONS_PATH)
                        .new(@connection.db, MIGRATIONS_PATH)
                        .files
      rescue StandardError
        []
      end
    end
  end
end
