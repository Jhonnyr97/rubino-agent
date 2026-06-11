# frozen_string_literal: true

require_relative "lib/rubino/version"

Gem::Specification.new do |spec|
  spec.name = "rubino-agent"
  spec.version = Rubino::VERSION
  spec.authors = ["Jhon Rojas"]
  spec.email = ["jhon@example.com"]

  spec.summary = "A lightweight Ruby coding and automation agent with persistent memory, sessions, and context compaction"
  spec.description = "A standalone, self-contained coding and automation agent built on ruby_llm. " \
                     "Provides an agent loop, persistent memory, SQLite sessions, context compaction, " \
                     "a job system, a tool registry, and an extensible UI layer."
  spec.homepage = "https://github.com/Jhonnyr97/rubino-agent"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.1.0"

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGELOG.md"
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files = Dir.chdir(__dir__) do
    # Use git if available, otherwise glob
    if system("git rev-parse --git-dir > /dev/null 2>&1")
      `git ls-files -z`.split("\x0").reject do |f|
        (File.expand_path(f) == __FILE__) ||
          f.start_with?(*%w[bin/ test/ spec/ features/ .git .github appveyor Gemfile])
      end
    else
      Dir.glob("{lib,exe}/**/*").reject { |f| File.directory?(f) } +
        %w[Gemfile Rakefile README.md CHANGELOG.md]
    end
  end

  spec.bindir = "exe"
  spec.executables = ["rubino"]
  spec.require_paths = ["lib"]

  # Core dependencies
  spec.add_dependency "dry-configurable", "~> 1.0"
  spec.add_dependency "dry-schema", "~> 1.13"
  spec.add_dependency "faraday", "~> 2.9"
  spec.add_dependency "faraday-retry", "~> 2.2"
  spec.add_dependency "oauth2", "~> 2.0"
  spec.add_dependency "puma", "~> 6.4"
  spec.add_dependency "rack", "~> 3.1"
  spec.add_dependency "ruby_llm", "~> 1.0"
  spec.add_dependency "ruby_llm-mcp", "~> 1.0"
  spec.add_dependency "rufus-scheduler", "~> 3.9"
  spec.add_dependency "sequel", "~> 5.0"
  spec.add_dependency "sqlite3", "~> 2.0"
  spec.add_dependency "thor", "~> 1.3"
  spec.add_dependency "zeitwerk", "~> 2.6"

  # CLI UI dependencies
  spec.add_dependency "kramdown", "~> 2.5"
  spec.add_dependency "kramdown-parser-gfm", "~> 1.1"
  spec.add_dependency "pastel", "~> 0.8"
  spec.add_dependency "tty-box", "~> 0.7"
  spec.add_dependency "tty-prompt", "~> 0.23"
  spec.add_dependency "tty-spinner", "~> 0.9"
  spec.add_dependency "tty-table", "~> 0.12"
  spec.add_dependency "unicode-display_width", "~> 2.6"

  # Reline used to ship with Ruby, but it was removed from default gems
  # in Ruby 4.0 and is now a regular gem. UI::LineInput depends on it for
  # the interactive prompt (history, completion, multi-line editing).
  spec.add_dependency "reline", "~> 0.5"

  # `csv` left the default gems in Ruby 3.4. The in-repo document converter
  # (Rubino::Documents) uses it for the CORE csv->Markdown format, so it is a
  # hard runtime dependency (the converter still falls back to a built-in
  # splitter if it is ever absent, but we ship it so csv always works).
  spec.add_dependency "csv", "~> 3.2"

  # Optional document-conversion extraction gems (Rubino::Documents, #6). These
  # are NOT hard runtime dependencies: each converter `require`s its gem lazily
  # inside begin/rescue LoadError and reports itself unavailable when the gem is
  # absent, so the module loads and runs with none of them installed (callers
  # then fall back to the shell-extraction hint). They are declared as
  # development dependencies so CI/specs can exercise the gem-backed converters;
  # an end user installs only the formats they need (e.g. `gem install roo`).
  # All MIT-licensed. html/xml use kramdown/rexml which are already present.
  #
  # NOTE: `ruby_powerpoint` is deliberately NOT in the dev bundle -- it pins
  # `rubyzip ~> 1.0`, which is irreconcilable with `docx`/`roo` (rubyzip ~> 2.x)
  # in a single Gemfile. The Pptx converter is therefore exercised by its
  # degradation path and unit-level shaping (a stubbed gem interface) rather
  # than the live gem; an end user who needs pptx installs ruby_powerpoint into
  # their own (compatible) environment. This is exactly the optional-require
  # design: a missing/absent gem never breaks the module.
  spec.add_development_dependency "docx", "~> 0.8"
  spec.add_development_dependency "pdf-reader", "~> 2.12"
  spec.add_development_dependency "roo", "~> 2.10"

  # Development dependencies
  spec.add_development_dependency "rack-test", "~> 2.1"
  spec.add_development_dependency "rspec", "~> 3.12"
  spec.add_development_dependency "rubocop", "~> 1.60"
  spec.add_development_dependency "rubocop-rspec", "~> 3.0"
end
