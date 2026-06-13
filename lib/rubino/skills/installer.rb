# frozen_string_literal: true

require "json"
require "tmpdir"

module Rubino
  module Skills
    # Installs skills from git repositories into the user skills dir (#4) —
    # the `rubino skills install/update/remove` backend. There is no
    # marketplace and nothing is vendored in the gem: a source is just a repo
    # (GitHub `owner/repo` shorthand or any git URL), shallow-cloned to a
    # tmpdir, scanned for the registry's own `<name>/SKILL.md` layout, and the
    # selected skill dirs are copied into `~/.rubino/skills` where the
    # existing Registry discovers them like any hand-written skill.
    #
    # Provenance is recorded per installed skill in `<skills-dir>/.sources.json`
    # (`name → {source, path, commit}`) so `update` can re-fetch from the
    # recorded source and `remove` knows which dirs this mechanism owns. The
    # dotfile name keeps it out of the registry's `*.md` / `*/SKILL.md` globs.
    class Installer
      SOURCES_FILE = ".sources.json"

      # GitHub shorthand: bare `owner/repo` (one slash, no scheme/host).
      GITHUB_SHORTHAND = %r{\A[\w.-]+/[\w.-]+\z}

      attr_reader :skills_dir

      def initialize(skills_dir: nil)
        # The same resolved home the registry's "~/.rubino/skills" entry
        # expands to (RUBINO_HOME → else ~/.rubino), so an install is
        # discovered without any config change.
        @skills_dir = skills_dir || File.join(Config::Loader.default_home_path, "skills")
      end

      # `owner/repo` → the GitHub URL; anything else is passed to git verbatim.
      def self.url_for(source)
        GITHUB_SHORTHAND.match?(source.to_s) ? "https://github.com/#{source}" : source.to_s
      end

      # Shallow-clones +source+ and yields (checkout_dir, head_sha); the tmp
      # checkout is deleted when the block returns. Returns the block's value,
      # or nil when the clone fails (unknown repo, no network — git's own
      # stderr is left visible as the diagnostic). The ONE network touchpoint,
      # so specs stub this method and never shell out.
      def fetch(source)
        Dir.mktmpdir("rubino-skills") do |dir|
          return nil unless system("git", "clone", "--depth", "1", "--quiet",
                                   self.class.url_for(source), dir, out: File::NULL)

          sha = IO.popen(["git", "-C", dir, "rev-parse", "HEAD"], &:read).strip
          yield dir, sha
        end
      end

      # Skills discoverable in a checkout, as `{name:, path:, description:}`
      # hashes (path = skill dir relative to the repo root). Recursive
      # (`**/` + the registry's DIR_GLOB) so catalog repos that nest skills
      # under a grouping dir are found too.
      def discover(checkout)
        Dir.glob(File.join("**", Registry::DIR_GLOB), base: checkout).sort.map do |rel|
          dir = File.dirname(rel)
          skill = Skill.new(path: File.join(checkout, rel))
          { name: skill.name, path: dir, description: skill.description.to_s }
        end
      end

      # Copies the discover-entries into the skills dir (replacing any prior
      # copy of the same name) and records their provenance.
      def install(entries, checkout:, source:, commit:)
        FileUtils.mkdir_p(@skills_dir)
        data = sources
        entries.each do |entry|
          dest = File.join(@skills_dir, entry[:name])
          FileUtils.rm_rf(dest)
          FileUtils.cp_r(File.join(checkout, entry[:path]), dest)
          data[entry[:name]] = { "source" => source, "path" => entry[:path], "commit" => commit }
        end
        write_sources(data)
      end

      # Re-fetches +names+ (default: every recorded skill) from their recorded
      # sources, one clone per distinct source. Returns name → :updated /
      # :up_to_date / :failed (clone failed, or the skill's recorded path no
      # longer holds a SKILL.md) / :unknown (no provenance entry).
      def update(names = [])
        data = sources
        names = data.keys if names.empty?
        results = {}
        names.group_by { |name| data.dig(name, "source") }.each do |source, group|
          next group.each { |name| results[name] = :unknown } if source.nil?

          fetched = fetch(source) do |checkout, sha|
            group.each { |name| results[name] = update_one(name, data[name], checkout, sha) }
            write_sources(data)
            true
          end
          group.each { |name| results[name] = :failed } unless fetched
        end
        results
      end

      # Deletes the skill dir + provenance entry. Returns false (nothing
      # touched) for a skill without a provenance entry — this mechanism only
      # removes what it installed.
      def remove(name) # rubocop:disable Naming/PredicateMethod -- "did I remove anything", a mutator reporting what it did
        data = sources
        return false unless data.key?(name)

        FileUtils.rm_rf(File.join(@skills_dir, name))
        data.delete(name)
        write_sources(data)
        true
      end

      # The provenance ledger (empty hash when absent or unparseable).
      def sources
        path = File.join(@skills_dir, SOURCES_FILE)
        File.file?(path) ? JSON.parse(File.read(path)) : {}
      rescue JSON::ParserError
        {}
      end

      private

      # Re-copies one skill from a fresh checkout, mutating its ledger entry's
      # commit in place (the caller persists the ledger once per source).
      def update_one(name, entry, checkout, sha)
        return :up_to_date if entry["commit"] == sha

        src = File.join(checkout, entry["path"])
        return :failed unless File.file?(File.join(src, "SKILL.md"))

        dest = File.join(@skills_dir, name)
        FileUtils.rm_rf(dest)
        FileUtils.cp_r(src, dest)
        entry["commit"] = sha
        :updated
      end

      def write_sources(data)
        FileUtils.mkdir_p(@skills_dir)
        File.write(File.join(@skills_dir, SOURCES_FILE), JSON.pretty_generate(data))
      end
    end
  end
end
