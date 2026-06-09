# Authoring & publishing gems

Building, structuring, testing and releasing a Ruby gem (Ruby 3.2–3.4, modern RubyGems/Bundler). For app dependency management with Bundler see `references/tooling.md`; for class/module design see `references/oo-design.md`.

## Scaffold a gem

Use Bundler's generator — never hand-roll the layout.

```bash
bundle gem rubino --test=rspec --ci=github --linter=rubocop
# flags: --exe (CLI binstub), --coc (code of conduct), --mit (license)
# --changelog (Keep a Changelog stub)
```

This produces the canonical skeleton:

```
rubino/
├── rubino.gemspec
├── Gemfile                 # only: gemspec + dev-only tools
├── Rakefile
├── README.md
├── CHANGELOG.md
├── LICENSE.txt
├── .rubocop.yml
├── .github/workflows/main.yml
├── bin/                    # dev helpers: console, setup (NOT shipped)
├── exe/                    # user-facing executables (shipped, on PATH)
├── sig/rubino.rbs          # RBS signatures (see errors-and-types.md)
├── lib/
│   ├── rubino.rb           # entrypoint: requires version + sets up loader
│   └── rubino/
│       └── version.rb      # Rubino::VERSION = "0.1.0"
└── spec/
```

**Gemfile vs gemspec.** Runtime + development *gem* dependencies belong in the `.gemspec`. The `Gemfile` is one line — `gemspec` — plus dev-only tools you don't want as formal dev dependencies. Don't duplicate dependency lists between them.

```ruby
# Gemfile
source "https://rubygems.org"
gemspec
gem "rake", "~> 13.0"   # tooling-only, fine to keep out of gemspec
```

## The entrypoint and version file

`version.rb` holds *only* the version constant so tooling (and `rake release`) can read it without loading the whole library.

```ruby
# lib/rubino/version.rb
module Rubino
  VERSION = "0.1.0"
end
```

```ruby
# lib/rubino.rb
# frozen_string_literal: true

require_relative "rubino/version"
require "zeitwerk"

module Rubino
  class Error < StandardError; end   # library base error (see errors-and-types.md)

  Loader = Zeitwerk::Loader.for_gem
  Loader.setup
end
```

`Zeitwerk::Loader.for_gem` configures the loader to manage `lib/`, automatically ignoring `lib/rubino.rb` itself and `lib/rubino/version.rb` (already required). Do not `require` your own source files after this — Zeitwerk autoloads them on first constant reference.

## The gemspec

```ruby
# rubino.gemspec
# frozen_string_literal: true

require_relative "lib/rubino/version"

Gem::Specification.new do |spec|
  spec.name        = "rubino"
  spec.version     = Rubino::VERSION
  spec.authors     = ["Jane Dev"]
  spec.email       = ["jane@example.com"]

  spec.summary     = "Short one-line description (< ~100 chars, no trailing period)."
  spec.description = "A longer paragraph describing what the gem does and why."
  spec.homepage    = "https://github.com/acme/rubino"
  spec.license     = "MIT"
  spec.required_ruby_version = ">= 3.2.0"

  # Metadata powers rubygems.org links + enables MFA-protected pushes.
  spec.metadata["homepage_uri"]       = spec.homepage
  spec.metadata["source_code_uri"]    = "https://github.com/acme/rubino"
  spec.metadata["changelog_uri"]      = "https://github.com/acme/rubino/blob/main/CHANGELOG.md"
  spec.metadata["bug_tracker_uri"]    = "https://github.com/acme/rubino/issues"
  spec.metadata["documentation_uri"]  = "https://rubydoc.info/gems/rubino"
  spec.metadata["rubygems_mfa_required"] = "true"

  # File list driven by git — never glob the whole dir (avoids shipping junk).
  gemspec = File.basename(__FILE__)
  spec.files = IO.popen(
    %w[git ls-files -z], chdir: __dir__, err: IO::NULL
  ) do |ls|
    ls.readlines("\x0", chomp: true).reject do |f|
      (f == gemspec) ||
        f.start_with?(*%w[bin/ test/ spec/ features/ .git .github appveyor Gemfile])
    end
  end

  spec.bindir      = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  # Runtime deps: required for the gem to function.
  spec.add_dependency "zeitwerk", "~> 2.6"
  spec.add_dependency "thor",     "~> 1.3"

  # Dev deps: needed only to develop/test the gem.
  spec.add_development_dependency "rspec", "~> 3.13"
end
```

Notes:

- **`git ls-files`** is the modern idiom — only tracked files ship. Untracked build artifacts, `.env`, `tmp/` never leak into the `.gem`.
- **`required_ruby_version`** gates installs on old Rubies with a clear error instead of a mysterious syntax failure.
- **`rubygems_mfa_required = "true"`** forces MFA for anyone pushing the gem — set it.
- Modern RubyGems: `add_dependency` *is* a runtime dependency. `add_runtime_dependency` is the old alias; either works, but don't pass a `:development` type to `add_dependency`.

### Dependency version policy

```ruby
spec.add_dependency "thor", "~> 1.3"        # >= 1.3.0, < 2.0  (RIGHT — pessimistic)
spec.add_dependency "thor", ">= 1.3", "< 3" # explicit range when you support 2 majors
```

Do / don't:

- DO use the pessimistic `~>` operator to allow compatible upgrades while excluding the next breaking major.
- DON'T pin to an exact version (`"= 1.3.2"`) in a library — it causes unresolvable conflicts in apps that depend on you. Exact pins belong in `Gemfile.lock` (apps), not gemspecs.
- DON'T leave a dependency unbounded (`>= 0`) — a future major can break your users silently.
- Keep the *floor* honest: require the lowest version whose API you actually use.

## Autoloading with Zeitwerk

Zeitwerk maps file paths to constant names. Follow its conventions and you never write `require` again.

```
lib/rubino.rb               -> (root file, loads the gem)
lib/rubino/client.rb        -> Rubino::Client
lib/rubino/http_client.rb   -> Rubino::HTTPClient   (acronym, see below)
lib/rubino/cli/runner.rb    -> Rubino::CLI::Runner
```

```ruby
# RIGHT: file name and constant agree
# lib/rubino/http_client.rb
module Rubino
  class HTTPClient; end
end
```

Acronyms need an inflection rule, or Zeitwerk expects `Rubino::HttpClient`:

```ruby
Loader = Zeitwerk::Loader.for_gem
Loader.inflector.inflect("http_client" => "HTTPClient", "cli" => "CLI")
Loader.setup
```

**Lazy (default) vs eager loading.** Lazy autoloading loads each file on first reference — ideal for libraries (fast boot, only pay for what's used). Eager-load when a host process forks (e.g. Puma/Sidekiq) or in CI to surface load errors:

```ruby
Loader.setup
Loader.eager_load if ENV["RUBINO_EAGER_LOAD"]   # or eager_load_force in tests
```

In CI, run `bin/rubocop` plus a tiny spec that calls `Rubino::Loader.eager_load` to catch naming mismatches before release.

## CLI gems: `exe/` vs `bin/`

- `bin/` holds **development** helpers (`bin/console`, `bin/setup`) that are *not* packaged.
- `exe/` holds **user-facing** executables that go on the user's PATH (`spec.bindir = "exe"`).

The executable file should be thin — parse nothing, delegate to a class.

```ruby
#!/usr/bin/env ruby
# frozen_string_literal: true
# exe/rubino   (chmod +x)

require "rubino"
Rubino::CLI.start(ARGV)
```

Use **Thor** for anything beyond a single flag — it gives subcommands, options, and help for free.

```ruby
# lib/rubino/cli.rb
require "thor"

module Rubino
  class CLI < Thor
    def self.exit_on_failure? = true   # exit 1 on errors, not raise

    desc "build PATH", "Build the project at PATH"
    option :force, type: :boolean, aliases: "-f", desc: "Overwrite existing output"
    def build(path)
      Builder.new(path, force: options[:force]).call
    end

    desc "version", "Print the version"
    def version = say(Rubino::VERSION)
  end
end
```

DON'T put business logic in the Thor class — it's hard to test and couples your domain to the CLI framework. Keep Thor as a thin adapter over plain objects (`Builder` above).

## Shipping non-code assets

Data files (templates, fixtures, certs, YAML) must be (a) tracked by git so `git ls-files` includes them, and (b) located at runtime relative to the file, never relative to CWD.

```ruby
# RIGHT: anchor on the gem's own directory
module Rubino
  ROOT      = File.expand_path("..", __dir__)          # gem root from lib/rubino.rb
  DATA_DIR  = File.expand_path("templates", __dir__)   # lib/rubino/templates

  def self.template(name)
    File.read(File.join(DATA_DIR, "#{name}.erb"))
  end
end
```

```ruby
# WRONG: relative to the process working directory — breaks once installed
File.read("templates/default.erb")      # NoMethodError-adjacent: file not found
File.read(Dir.pwd + "/lib/rubino/...")  # depends on where the user ran the command
```

Use `__dir__` (the directory of the current file) over `File.dirname(__FILE__)` — same result, less noise. Place assets *under* `lib/` (e.g. `lib/rubino/templates/`) so Zeitwerk's path mapping isn't disturbed by them — Zeitwerk ignores non-`.rb` files automatically, but keeping them in a clearly-data subdir is cleanest. For larger data trees, `Loader.ignore("#{__dir__}/rubino/templates")` is explicit.

## Namespacing & avoiding constant pollution

Everything lives under your top-level module. One namespace, one top-level constant.

```ruby
# RIGHT
module Rubino
  class Client; end
  Config = Data.define(:timeout, :retries)
end
```

```ruby
# WRONG: leaks Client and Config into Object — collides with other gems
class Client; end
Config = Struct.new(:timeout)
```

Don't reopen/monkey-patch core classes from a gem; if you must extend, use **refinements** (lexically scoped) — see `references/metaprogramming.md`. Don't define top-level methods or constants.

## Semantic versioning & CHANGELOG

Follow [SemVer](https://semver.org): `MAJOR.MINOR.PATCH`.

- **PATCH** (`0.1.0 → 0.1.1`): backward-compatible bug fixes.
- **MINOR** (`0.1.0 → 0.2.0`): backward-compatible new features.
- **MAJOR** (`0.x → 1.0`, `1.x → 2.0`): breaking changes.
- `0.y.z` means "unstable" — minor bumps may break. Cut `1.0.0` when the API is committed.

Maintain a [Keep a Changelog](https://keepachangelog.com) `CHANGELOG.md` — human-curated, newest first, grouped by Added/Changed/Deprecated/Removed/Fixed/Security.

```markdown
# Changelog

## [Unreleased]

## [0.2.0] - 2026-06-09
### Added
- `Rubino::Client#stream` for incremental responses.
### Deprecated
- `Client#fetch_all`; use `#stream`. Removed in 1.0.

## [0.1.0] - 2026-05-01
### Added
- Initial release.
```

DON'T auto-generate the changelog from raw commit subjects — curate it for humans who need to decide whether to upgrade.

## README

A gem README should let a reader install and succeed in 60 seconds, in this order:

1. One-sentence what-and-why.
2. Installation: `bundle add rubino` (modern) or the `gem "rubino"` Gemfile line + `gem install rubino`.
3. Usage — a copy-pasteable minimal example that actually runs.
4. Configuration options.
5. Compatibility (supported Ruby/Rails versions).
6. Development & contributing, License.

Show real code, not API tables. Keep the top example small.

## Testing a gem

Use RSpec (or Minitest — see `references/testing.md`). Test the *public* API against the namespace, not file internals (Zeitwerk autoloads).

```ruby
# spec/rubino_spec.rb
RSpec.describe Rubino do
  it "has a version" do
    expect(Rubino::VERSION).to match(/\A\d+\.\d+\.\d+/)
  end

  it "eager loads without naming errors" do
    expect { Rubino::Loader.eager_load }.not_to raise_error
  end
end
```

### Multi-version testing with Appraisal

When your gem must support several versions of a dependency (e.g. Rails 7.1 and 8.0), use the **appraisal** gem to run the suite against each.

```ruby
# Appraisals
appraise "rails-7.1" do
  gem "rails", "~> 7.1.0"
end
appraise "rails-8.0" do
  gem "rails", "~> 8.0.0"
end
```

```bash
bundle exec appraisal install           # generates gemfiles/*.gemfile + locks
bundle exec appraisal rspec             # runs the suite under every gemfile
bundle exec appraisal rails-8.0 rspec   # just one
```

### CI matrix across Ruby versions

```yaml
# .github/workflows/main.yml
name: CI
on: [push, pull_request]
jobs:
  test:
    runs-on: ubuntu-latest
    strategy:
      fail-fast: false
      matrix:
        ruby: ["3.2", "3.3", "3.4"]
        gemfile: ["gemfiles/rails_7.1.gemfile", "gemfiles/rails_8.0.gemfile"]
    env:
      BUNDLE_GEMFILE: ${{ matrix.gemfile }}
    steps:
      - uses: actions/checkout@v4
      - uses: ruby/setup-ruby@v1
        with:
          ruby-version: ${{ matrix.ruby }}
          bundler-cache: true   # bundle install + cache gems
      - run: bundle exec rspec
      - run: bundle exec rubocop
```

Match the Ruby floor in the matrix to `required_ruby_version`.

## Building & releasing

Bundler's `gem` tasks (loaded by `Bundler::GemHelper.install_tasks` in the Rakefile) drive the release:

```bash
rake build      # builds pkg/rubino-0.2.0.gem from the gemspec
rake install    # builds + installs locally for smoke-testing
rake release     # tags vX.Y.Z, pushes the tag, and gem push to rubygems.org
```

`rake release` derives the version from `Rubino::VERSION`, so the release flow is: bump `version.rb` → update `CHANGELOG.md` → commit → `rake release`. It refuses to release with uncommitted changes.

### Credentials, API key & MFA

- `gem push` reads `~/.gem/credentials` (`chmod 0600`). Get a key with `gem signin` or from rubygems.org → Settings → API keys, scoped to *push only*.
- Enable account-level **MFA** and set `rubygems_mfa_required = "true"` in metadata (above) so pushes require MFA even if a key leaks.

### Trusted publishing / OIDC from CI (preferred)

Don't store a long-lived API key in CI secrets. Configure **trusted publishing** on rubygems.org (per-gem, bound to your GitHub repo + workflow), then publish keylessly via OIDC:

```yaml
  release:
    runs-on: ubuntu-latest
    if: startsWith(github.ref, 'refs/tags/v')
    permissions:
      id-token: write   # required for OIDC
      contents: write
    steps:
      - uses: actions/checkout@v4
      - uses: ruby/setup-ruby@v1
        with: { ruby-version: "3.4", bundler-cache: true }
      - uses: rubygems/release-gem@v1   # exchanges OIDC token, runs gem push
```

This issues a short-lived credential per run — no secret to leak or rotate.

### Yanking

A pushed version is immutable — you cannot overwrite it. To pull a broken/insecure release:

```bash
gem yank rubino -v 0.2.0     # removes it as an install candidate
```

Yanking does NOT free the version number — you cannot re-push `0.2.0`; ship `0.2.1`. Yank only for serious breakage (security, unusable). Prefer a fast follow-up release for ordinary bugs so existing pins keep resolving.

## Backward-compat & deprecation policy

Within a major version, don't break the public API. To remove/rename something, deprecate first, remove in the next major.

```ruby
# RIGHT: warn, delegate, document the removal version
def fetch_all(*args, **kwargs)
  warn "[DEPRECATION] Rubino::Client#fetch_all is deprecated and will be " \
       "removed in 1.0. Use #stream instead.", uplevel: 1
  stream(*args, **kwargs).to_a
end
```

```ruby
# WRONG: silently change behavior or delete the method in a minor release
```

- Use `Kernel#warn ... uplevel: 1` so the warning points at the *caller's* line.
- Record every deprecation under `### Deprecated` in the CHANGELOG with the planned removal version.
- Treat anything documented in the README/public methods as API. Mark genuinely-internal classes (`@api private` in docs, or a `Rubino::Internal` namespace) so users know what's safe to break.
- For richer deprecation (Rails-style), `ActiveSupport::Deprecation` provides per-gem deprecator objects. See `references/errors-and-types.md` for warnings/deprecation mechanics.

## Quick checklist

- Scaffold with `bundle gem <name>` (`--test`, `--ci`, `--linter`); don't hand-roll.
- `version.rb` contains only `VERSION`; the gemspec `require_relative`s it.
- `spec.files` from `git ls-files`; never glob the whole directory.
- Set `required_ruby_version`, metadata URIs, and `rubygems_mfa_required = "true"`.
- Use `~>` pessimistic constraints in the gemspec; never exact-pin a library dep.
- Runtime deps via `add_dependency`; dev/test deps via `add_development_dependency`.
- Let Zeitwerk autoload; match file names to constants; register acronym inflections.
- User executables in `exe/` + `spec.bindir`; dev helpers in `bin/`; Thor as a thin CLI adapter.
- One top-level module; no top-level constants/methods; no core monkey-patching.
- Locate bundled data with `File.expand_path(..., __dir__)`, never CWD-relative.
- SemVer strictly; curate a Keep a Changelog `CHANGELOG.md`.
- CI matrix over supported Rubies; Appraisal for multi-version deps; eager-load in CI.
- Release via `rake release`; prefer OIDC trusted publishing over stored API keys.
- Versions are immutable — `gem yank` for emergencies; bump for fixes.
- Deprecate (warn + `uplevel: 1`) before removing; remove only on a major bump.
