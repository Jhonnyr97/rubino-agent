# frozen_string_literal: true

module Rubino
  # The set of directory roots the agent is allowed to work in.
  #
  # Historically rubino had exactly ONE root, resolved at launch from
  # terminal.cwd or Dir.pwd, and every tool re-derived it. This module turns
  # that single root into an ordered SET of roots: the primary (launch) root
  # plus any directories added via `--add-dir` / `/add-dir`. The default — no
  # extra dirs — is byte-identical to the old single-root behaviour.
  #
  # Modelled on Claude Code's `--add-dir`: extra roots widen the write/edit
  # sandbox (see Tools::Base#within_workspace?) so the agent can touch files
  # under any allowed root, e.g. a service and its client library at once.
  module Workspace
    @added = []
    @mutex = Mutex.new

    class << self
      # The primary root: terminal.cwd when set, else the process cwd. This is
      # the same rule Tools::Base#workspace_root has always used, kept as the
      # single source of truth so the @-picker, shell/test cwd, file API and
      # attachment downloader all agree on "the" root.
      def primary_root
        Rubino.configuration&.dig("terminal", "cwd") || Dir.pwd
      end

      # Every allowed root: the primary first, then each added dir, de-duped on
      # canonical path so re-adding the launch dir (or the same dir twice) is a
      # no-op. Returns plain strings.
      def roots
        @mutex.synchronize do
          ordered = [primary_root, *@added]
          seen = Set.new
          ordered.filter_map do |dir|
            real = canonical(dir)
            next unless real
            next if seen.include?(real)

            seen << real
            dir
          end
        end
      end

      # Canonical (realpath, symlinks resolved) form of every root — what the
      # sandbox compares against.
      def canonical_roots
        roots.filter_map { |dir| canonical(dir) }
      end

      # Adds an extra allowed root. Returns the canonical path on success, or
      # raises ArgumentError with a human-readable reason when the dir doesn't
      # exist / isn't a readable directory. realpath-resolves so a symlinked
      # add-dir lands on its true destination (and matches the sandbox check).
      def add(dir)
        expanded = File.expand_path(dir.to_s)
        raise ArgumentError, "no such directory: #{dir}" unless File.directory?(expanded)
        raise ArgumentError, "not readable: #{dir}" unless File.readable?(expanded)

        real = File.realpath(expanded)
        @mutex.synchronize do
          @added << real unless @added.include?(real) || canonical(primary_root) == real
        end
        real
      end

      # Test/teardown hook: drop all added roots (the primary is always derived
      # live from config/cwd, so it can't be reset here).
      def reset!
        @mutex.synchronize { @added = [] }
      end

      private

      def canonical(path)
        return nil if path.nil? || path.to_s.empty?

        File.realpath(File.expand_path(path.to_s))
      rescue StandardError
        nil
      end
    end
  end
end
