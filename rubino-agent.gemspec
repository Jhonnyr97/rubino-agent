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

  # The Linux Landlock write-jail helper (Security::Sandbox). extconf.rb builds
  # a tiny standalone `rubino-landlock` executable at install time. It DEGRADES
  # GRACEFULLY: on macOS/Windows, without a compiler, or without Landlock
  # headers it writes a no-op Makefile and exits 0, so `gem install` never
  # breaks — the sandbox just reports the Linux mechanism unavailable and fails
  # open (with a loud banner). The Ruby side also compiles it on first run as a
  # fallback, so a source checkout / pristine bundle still gets confinement.
  spec.extensions = ["ext/landlock/extconf.rb"]

  # Core dependencies
  spec.add_dependency "dry-configurable", "~> 1.0"
  spec.add_dependency "dry-schema", "~> 1.13"
  spec.add_dependency "faraday", "~> 2.9"
  spec.add_dependency "faraday-retry", "~> 2.2"
  # Readability-style main-content extraction in the webfetch tool.
  spec.add_dependency "nokogiri", "~> 1.18"
  # HTML -> Markdown serialization for the webfetch tool. Purpose-built for
  # scraping messy web HTML: it drops unknown/attributed inline tags to their
  # text, decodes entities, and emits clean GFM — where kramdown's `to_kramdown`
  # (used by Documents for CLEAN document HTML) leaks literal <span class>/<a>
  # wrappers and kramdown-only IAL syntax on real web pages. MIT-licensed;
  # depends on nokogiri, already present.
  spec.add_dependency "reverse_markdown", "~> 3.0"
  # Headless-browser (Chrome DevTools Protocol) rendering for the webfetch tool's
  # JS tier (SPAs). OPTIONAL, never bundled: WebFetchTool `require`s it lazily
  # inside begin/rescue LoadError (Web::JsRenderer#available?), so the gem loads
  # and every static fetch works with ferrum absent. An end user who wants JS
  # rendering installs it + a Chrome/Chromium binary on demand (see install.sh).
  # Declared as a DEVELOPMENT dependency so CI/specs can exercise the JS path.
  # MIT-licensed; needs only Ruby + a Chrome binary (no Selenium/WebDriver).
  spec.add_development_dependency "ferrum", "~> 0.15"
  spec.add_dependency "oauth2", "~> 2.0"
  spec.add_dependency "puma", "~> 6.4"
  spec.add_dependency "rack", "~> 3.1"
  # Floor is 1.16: the adapter wires native providers through ruby_llm's
  # generic `<provider>_api_base=` setters (deepseek/mistral/etc., #482), which
  # only exist from ruby_llm 1.16.0 ("api_base support for all providers"). On
  # 1.15 those setters are absent and the call dies with NoMethodError at
  # runtime, so a published-gem install must not resolve below 1.16.
  spec.add_dependency "ruby_llm", ">= 1.16", "< 2.0"
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
  spec.add_dependency "rouge", "~> 4.2"
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

  # Optional JS/TS/TSX skeletonizer parser (Rubino::Compression's
  # TreeSitterCodeSkeleton). Like the document converters above this is NOT a
  # hard runtime dependency: the skeletoner `require`s it lazily inside
  # begin/rescue and returns a NO-OP (the original output is sent unchanged)
  # when the gem — or a grammar it would download on first use — is absent. It
  # is a DEVELOPMENT dependency only so CI/specs exercise the real parser; an
  # end user who wants JS/TS compression installs it themselves. MIT-licensed,
  # ships precompiled grammars (no compile toolchain needed at install).
  spec.add_development_dependency "tree_sitter_language_pack", "~> 1.10"

  # Development dependencies
  spec.add_development_dependency "parallel_tests", "~> 4.7"
  spec.add_development_dependency "rack-test", "~> 2.1"
  spec.add_development_dependency "rspec", "~> 3.12"
  spec.add_development_dependency "rubocop", "~> 1.60"
  spec.add_development_dependency "rubocop-rspec", "~> 3.0"
end
