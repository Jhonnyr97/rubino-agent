# frozen_string_literal: true

require "sequel"
require "fileutils"

module Rubino
  module Database
    # Manages the SQLite database connection via Sequel.
    # Handles connection creation, WAL mode setup, and provides
    # access to the underlying Sequel::Database instance.
    class Connection
      # SQLite path values that resolve to an ephemeral, in-memory database
      # rather than an on-disk file. These must skip File.expand_path
      # (which would turn ":memory:" into a literal "./:memory:" file) and
      # FileUtils.mkdir_p on the parent directory.
      MEMORY_PATHS = [":memory:", "file::memory:"].freeze

      attr_reader :db_path

      def initialize(db_path)
        @db_path = memory_path?(db_path) ? db_path : File.expand_path(db_path)
      end

      # Returns the Sequel database connection (lazy-initialized)
      def db
        @db ||= connect!
      end

      # Tests if the database is accessible
      def healthy?
        db.execute("SELECT 1")
        true
      rescue StandardError
        false
      end

      # Closes the database connection
      def close
        @db&.disconnect
        @db = nil
      end

      # True when @db_path refers to an in-memory SQLite instance.
      def memory?
        memory_path?(@db_path)
      end

      private

      def memory_path?(path)
        MEMORY_PATHS.any? { |p| path == p } || path.to_s.start_with?("file::memory:")
      end

      def connect!
        FileUtils.mkdir_p(File.dirname(@db_path)) unless memory?

        connection = Sequel.sqlite(@db_path)

        # WAL has no meaning for :memory: and triggers a warning; only apply on disk.
        unless memory?
          connection.run("PRAGMA journal_mode=WAL")
          connection.run("PRAGMA synchronous=NORMAL")
        end
        connection.run("PRAGMA foreign_keys=ON")
        connection.run("PRAGMA busy_timeout=5000")

        connection
      end
    end
  end
end
