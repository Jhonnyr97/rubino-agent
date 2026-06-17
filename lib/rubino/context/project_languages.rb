# frozen_string_literal: true

module Rubino
  module Context
    # Detects which programming languages a project uses, by looking for
    # well-known marker files in the workspace root (Gemfile → ruby,
    # requirements.txt → python, …). This is what lets language-specific
    # built-in skills (e.g. ruby-expert) stay OPT-IN for the languages a
    # project doesn't use: a Python project no longer gets the agent
    # auto-branding itself as Ruby/Rails just because a Ruby skill ships
    # with the gem. The skill is still discoverable and loadable on demand —
    # detection only governs whether it's surfaced in the auto-load catalogue.
    #
    # Deliberately conservative and cheap: it checks for the presence of a
    # small set of marker FILENAMES, and (only when no marker is found) does a
    # shallow scan for source-file extensions. It never reads file contents and
    # never walks the full tree, so it stays fast even in a large repo.
    module ProjectLanguages
      # Marker filenames that unambiguously identify a language's project.
      # Checked first because they're the strongest signal and the cheapest.
      MARKER_FILES = {
        "ruby" => %w[Gemfile Gemfile.lock Rakefile .ruby-version config.ru],
        "python" => %w[requirements.txt pyproject.toml setup.py setup.cfg Pipfile poetry.lock],
        "javascript" => %w[package.json yarn.lock pnpm-lock.yaml],
        "go" => %w[go.mod go.sum],
        "rust" => %w[Cargo.toml Cargo.lock],
        "java" => %w[pom.xml build.gradle build.gradle.kts]
      }.freeze

      # Source extensions used as a fallback when no marker file is present
      # (e.g. a bare scratch dir with a couple of .py files). Globbed shallowly
      # (top level only) so this never turns into a full-tree walk.
      EXTENSIONS = {
        "ruby" => %w[rb],
        "python" => %w[py],
        "javascript" => %w[js mjs ts tsx jsx],
        "go" => %w[go],
        "rust" => %w[rs],
        "java" => %w[java kt]
      }.freeze

      module_function

      # Returns the Set of detected language tokens for the given root
      # (defaults to the primary workspace root). Empty when nothing matches —
      # callers treat "unknown language" as "don't gate", so a project we can't
      # classify still sees every skill.
      def detect(root: nil)
        root ||= safe_primary_root
        return Set.new unless root && File.directory?(root)

        langs = detect_by_marker(root)
        return langs unless langs.empty?

        detect_by_extension(root)
      rescue StandardError
        # Detection is a best-effort hint; a probe failure (unreadable dir,
        # weird permissions) must never break prompt assembly. Fall back to
        # "unknown", which the caller treats as ungated.
        Set.new
      end

      # True when +language+ (case-insensitive) is among the detected languages
      # for the root. Used by the skills registry to decide whether a
      # language-gated built-in skill belongs in the auto-load catalogue.
      def uses?(language, root: nil)
        detect(root: root).include?(language.to_s.downcase)
      end

      def detect_by_marker(root)
        MARKER_FILES.each_with_object(Set.new) do |(lang, files), acc|
          acc << lang if files.any? { |f| File.exist?(File.join(root, f)) }
        end
      end

      def detect_by_extension(root)
        EXTENSIONS.each_with_object(Set.new) do |(lang, exts), acc|
          glob = File.join(root, "*.{#{exts.join(",")}}")
          acc << lang unless Dir.glob(glob).empty?
        end
      end

      def safe_primary_root
        Rubino::Workspace.primary_root
      rescue StandardError
        Dir.pwd
      end
    end
  end
end
