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

      # True when the on-disk file is present but unopenable because its image
      # is malformed/truncated (`SQLite3::CorruptException`). A brand-new or
      # absent file is NOT corrupt — it's just not initialized yet — so this is
      # the signal that distinguishes "needs setup" from "needs recovery".
      def corrupt?
        return false if memory? || !File.exist?(@db_path)

        db.execute("SELECT 1")
        false
      rescue StandardError => e
        corruption_error?(e)
      end

      # Quarantine an unopenable database file (and its WAL/SHM siblings) by
      # renaming them aside to `<name>.corrupt-<timestamp>` so a fresh DB can be
      # created in their place WITHOUT silently destroying the bytes — the user
      # can still hand them to `sqlite3 .recover` if they want. Returns the path
      # the main file was moved to, or nil when there was nothing to move.
      def quarantine!
        return nil if memory? || !File.exist?(@db_path)

        close
        stamp = Time.now.strftime("%Y%m%d%H%M%S")
        moved = nil
        ["", "-wal", "-shm"].each do |suffix|
          src = "#{@db_path}#{suffix}"
          next unless File.exist?(src)

          dest = "#{@db_path}.corrupt-#{stamp}#{suffix}"
          File.rename(src, dest)
          moved = dest if suffix.empty?
        end
        moved
      end

      # True when +error+ (or anything in its cause chain) is the SQLite
      # "database disk image is malformed" corruption error. Sequel wraps the
      # driver exception in a Sequel::DatabaseError, so we walk #cause and also
      # match the wrapped class name without hard-depending on the sqlite3 gem
      # constant being loaded.
      def corruption_error?(error)
        e = error
        while e
          return true if e.class.name.to_s.include?("SQLite3::CorruptException")
          return true if e.message.to_s.include?("database disk image is malformed")

          e = e.cause
        end
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
        existed = memory? || File.exist?(@db_path)
        FileUtils.mkdir_p(File.dirname(@db_path)) unless memory?

        connection = Sequel.sqlite(@db_path)

        # A freshly-created database holds session content — owner-only, like
        # the rest of the home's secrets (#65). Creation-only so an operator
        # who deliberately re-chmods an existing file is respected.
        File.chmod(0o600, @db_path) unless existed

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
