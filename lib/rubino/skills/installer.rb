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

      # The only shape a skill `name:` may take before it becomes a directory
      # under the skills root: lowercase alphanumerics in hyphen-separated
      # segments (Claude Code's skill-name grammar). This is the CWE-22
      # allowlist defense — same class as the Zed CVE-2026-27800 / Anthropic
      # EscapeRoute CVE-2025-53110 traversal bugs: it admits no path separator,
      # no `..`, no dot, no NUL, no leading/trailing hyphen, no absolute path,
      # nothing but `[a-z0-9-]`.
      NAME_ALLOWLIST = /\A[a-z0-9]+(?:-[a-z0-9]+)*\z/
      NAME_MAX_LEN = 64

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
      # copy of the same name) and records their provenance. Entries whose
      # name isn't a safe single path segment (a hostile repo can put
      # `name: ../../EVIL` in its frontmatter) are skipped — never written,
      # never recorded — so an install can't write or delete anything outside
      # the skills dir (SKILL-1).
      def install(entries, checkout:, source:, commit:)
        FileUtils.mkdir_p(@skills_dir)
        # Read-modify-write the ledger under an exclusive lock so N parallel
        # installs don't lose updates (each reading the same base and the last
        # writer clobbering the rest → orphaned, unremovable skills). The file
        # copies stay inside the locked region: each install owns a distinct
        # name (its own dest dir), so they don't collide, and keeping them under
        # the lock means the ledger and the on-disk dirs can't diverge.
        update_sources do |data|
          entries.each do |entry|
            name = entry[:name]
            dest = safe_dest(name) or next

            FileUtils.rm_rf(dest)
            FileUtils.cp_r(File.join(checkout, entry[:path]), dest)
            data[name] = { "source" => source, "path" => entry[:path], "commit" => commit }
          end
        end
      end

      # Re-fetches +names+ (default: every recorded skill) from their recorded
      # sources, one clone per distinct source. Returns name → :updated /
      # :up_to_date / :failed (clone failed, or the skill's recorded path no
      # longer holds a SKILL.md) / :unknown (no provenance entry).
      def update(names = [])
        results = {}
        # One locked read-modify-write for the whole update so it can't race a
        # concurrent install/remove/update (lost-update → orphaned entries). The
        # network clones run inside the lock; updates are infrequent and this
        # keeps the ledger consistent with what was re-fetched.
        update_sources do |data|
          names = data.keys if names.empty?
          names.group_by { |name| data.dig(name, "source") }.each do |source, group|
            next group.each { |name| results[name] = :unknown } if source.nil?

            fetched = fetch(source) do |checkout, sha|
              group.each { |name| results[name] = update_one(name, data[name], checkout, sha) }
              true
            end
            group.each { |name| results[name] = :failed } unless fetched
          end
        end
        results
      end

      # Deletes the skill dir + provenance entry. Returns false (nothing
      # touched) for a skill without a provenance entry — this mechanism only
      # removes what it installed.
      def remove(name)
        removed = false
        update_sources do |data|
          next unless data.key?(name)

          # Confine the delete to the skills dir even if a pre-fix ledger recorded
          # a traversal key (defense in depth — install now refuses such names).
          dest = safe_dest(name)
          FileUtils.rm_rf(dest) if dest
          data.delete(name)
          removed = true
        end
        removed
      end

      # The provenance ledger (empty hash when absent or unparseable). Reads
      # under a shared lock so it can't observe a writer's intermediate state.
      def sources
        raw = Util::AtomicFile.read_shared(sources_path)
        raw ? JSON.parse(raw) : {}
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

        dest = safe_dest(name)
        return :failed unless dest

        FileUtils.rm_rf(dest)
        FileUtils.cp_r(src, dest)
        entry["commit"] = sha
        :updated
      end

      # Resolves +name+ to its destination dir inside the skills dir, or nil
      # when the name isn't a safe single path segment. The frontmatter `name`
      # is attacker-controlled (it comes straight from a cloned repo's
      # SKILL.md), so it gets the two independent CWE-22 defenses:
      #   1. a strict allowlist — only `[a-z0-9]` hyphen-segments, length-capped
      #      — which already excludes `/`, `\`, `..`, `~`, NUL, and absolutes; and
      #   2. path confinement — canonicalize the parent against the skills root
      #      and assert the resolved dest sits directly under it (the trailing
      #      separator guards against a sibling whose name shares the root's
      #      prefix), so even if the allowlist were ever loosened the write can't
      #      escape. realpath failure is treated as deny, never as a fallback.
      def safe_dest(name)
        name = name.to_s
        return nil unless name.length <= NAME_MAX_LEN && NAME_ALLOWLIST.match?(name)

        root = real_skills_root or return nil
        dest = File.expand_path(name, root)
        return nil unless dest == File.join(root, name) &&
                          dest.start_with?(root + File::SEPARATOR)

        dest
      end

      # The canonical (symlink-resolved) skills root, creating it if needed so
      # realpath can resolve it. nil — i.e. deny — if it can't be resolved.
      def real_skills_root
        FileUtils.mkdir_p(@skills_dir)
        File.realpath(@skills_dir)
      rescue SystemCallError
        nil
      end

      def sources_path
        File.join(@skills_dir, SOURCES_FILE)
      end

      # Exclusive, atomic read-modify-write of the ledger. Yields the parsed
      # hash (mutated in place by the block); the post-block state is written
      # back via temp-file + rename so it's never torn or lost under concurrent
      # installs/updates/removes.
      def update_sources
        FileUtils.mkdir_p(@skills_dir)
        Util::AtomicFile.update(sources_path) do |raw|
          data = parse_ledger(raw)
          yield(data)
          JSON.pretty_generate(data)
        end
      end

      def parse_ledger(raw)
        raw && !raw.empty? ? JSON.parse(raw) : {}
      rescue JSON::ParserError
        {}
      end
    end
  end
end
