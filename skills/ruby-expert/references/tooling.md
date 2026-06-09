# Tooling, environment & debugging

The Ruby toolchain for Ruby 3.2–3.4 and Rails 7.1–8.x. Practical commands, modern idioms, and explicit do/don't. For test frameworks see `references/testing.md`; for building/publishing your own gem see `references/gem-authoring.md`.

## Bundler

`Bundler` resolves and locks dependencies. The `Gemfile` declares them; `Gemfile.lock` pins the exact resolved versions.

### Gemfile

```ruby
source "https://rubygems.org"

ruby file: ".ruby-version"   # single source of truth; or: ruby "3.4.2"

gem "rails", "~> 8.0.1"       # pessimistic: >= 8.0.1, < 8.1
gem "pg", "~> 1.5"           # >= 1.5, < 2.0
gem "puma", ">= 6.0"

group :development, :test do
  gem "debug", require: false   # require: false → load only when you need it
  gem "rspec-rails"
  gem "factory_bot_rails"
end

group :development do
  gem "rubocop", require: false
  gem "ruby-lsp", require: false
end

group :production do
  gem "rack-mini-profiler", require: false
end

gem "nokogiri", platforms: %i[ruby]
gem "tzinfo-data", platforms: %i[mingw mswin x64_mingw jruby]
```

### Version constraints

| Constraint | Means | Use when |
|---|---|---|
| `~> 1.4.2` | `>= 1.4.2, < 1.5.0` | lock to a patch line |
| `~> 1.4` | `>= 1.4.0, < 2.0.0` | allow minor upgrades |
| `>= 1.4` | any future version | libraries, rarely apps |
| `1.4.2` | exact | pinning a known-good/broken version |

Prefer `~>` (pessimistic) for apps. Avoid bare `gem "foo"` with no constraint in a long-lived app — it lets a major bump slip in on a fresh `bundle install` against a deleted lock.

### Gemfile.lock commit policy

- **Applications**: ALWAYS commit `Gemfile.lock`. It guarantees every machine/CI/prod runs identical versions.
- **Gems/libraries**: do NOT commit `Gemfile.lock` (it's typically git-ignored). The consumer's app resolves versions. See `references/gem-authoring.md`.

### Everyday commands

```bash
bundle install              # install per the lock; resolve only new/changed gems
bundle install --jobs 4     # parallel
bundle update               # re-resolve EVERYTHING to newest allowed — be careful
bundle update rails         # update ONLY rails (and its deps) — prefer this
bundle update --conservative rails  # update rails, hold its shared deps if possible
bundle outdated             # list gems with newer versions available
bundle outdated --filter-major   # only majors
bundle lock --add-platform x86_64-linux  # add a platform for CI/Docker
bundle lock --update        # refresh lock without installing
bundle clean --force        # remove unused installed gem versions
```

WRONG: running `bundle update` (no args) to fix one gem — it churns the whole lock and ships unreviewed upgrades.
RIGHT: `bundle update <gem>` for the specific dependency, then review the lock diff.

### bundle exec, binstubs

`bundle exec <cmd>` runs a command with the gem versions from the lock, not whatever is globally installed.

```bash
bundle exec rspec
bundle exec rake db:migrate
```

Binstubs are wrappers in `bin/` that pin the bundle so you can drop `bundle exec`:

```bash
bundle binstubs rspec-core        # creates bin/rspec
bundle binstubs rubocop --force
./bin/rspec                       # equivalent to `bundle exec rspec`
```

Rails apps ship `bin/rails`, `bin/rake`, `bin/setup`. Commit `bin/` so the team shares the same entrypoints. A `Gemfile`-aware shim is also provided by `mise`/`asdf` reshims and by `rbenv`'s rehash.

## Ruby version managers

Pick ONE per machine — mixing rbenv and rvm corrupts `PATH`. The `.ruby-version` file in the project root names the interpreter; most managers auto-switch on `cd`.

```
# .ruby-version
3.4.2
```

| Manager | Mechanism | Notes |
|---|---|---|
| **rbenv** | shims + `PATH`, rehash | lightweight, no shell hijack; `ruby-build` plugin installs versions |
| **rvm** | shell function overrides `cd` | heavyweight, manages gemsets; older, more invasive |
| **chruby** | tiny shell function + `ruby-install` | minimal, no shims, explicit |
| **asdf** | shims, multi-language (`.tool-versions`) | one tool for ruby+node+python |
| **mise** | fast Rust asdf-compatible (`.mise.toml` or `.tool-versions`) | modern default; auto-installs, env management |
| **rv** | new Rust Ruby manager (early/experimental) | watch but don't depend on it in prod yet |

```bash
# rbenv
rbenv install 3.4.2
rbenv local 3.4.2        # writes .ruby-version
rbenv rehash            # after installing a gem with a binstub

# mise
mise use ruby@3.4.2     # writes to .mise.toml / .tool-versions
mise install
mise exec -- ruby -v

# chruby + ruby-install
ruby-install ruby 3.4.2
chruby 3.4.2

# asdf
asdf install ruby 3.4.2
asdf local ruby 3.4.2
```

DO commit `.ruby-version` (and `.tool-versions`/`.mise.toml` if the team uses that manager). It keeps dev and CI on the same interpreter. Don't hardcode the version string in the `Gemfile` AND `.ruby-version` separately — point the Gemfile at the file: `ruby file: ".ruby-version"`.

## Debugging

### The `debug` gem (stdlib since Ruby 3.1)

`debug` is the modern, official debugger — it replaces `byebug`. Drop a breakpoint with `binding.break` (aliases: `binding.b`, `debugger`).

```ruby
require "debug"   # not needed in Rails dev; add `gem "debug"` to :development/:test

def process(order)
  binding.break   # execution stops here; opens a console
  total = order.line_items.sum(&:price)
  total
end
```

At the prompt:

```
(rdbg) n        # next line (step over)
(rdbg) s        # step into
(rdbg) c        # continue
(rdbg) fin      # finish current frame (step out)
(rdbg) bt       # backtrace
(rdbg) info     # local variables
(rdbg) p total  # evaluate Ruby
(rdbg) break Order#total   # set a breakpoint by method
(rdbg) catch StandardError # break when an exception is raised
(rdbg) outline  # methods available on the current object
```

Conditional and one-shot breakpoints:

```ruby
binding.break(do: "p user.id")            # run a command then continue
binding.break if order.total > 1_000      # plain Ruby guard
```

Remote/attach debugging (great for servers, Docker):

```bash
rdbg --open --port 12345 -- ruby app.rb   # or: bundle exec rdbg -O ...
rdbg --attach 12345                        # attach from another terminal
```

### pry / pry-byebug

`pry` is a richer REPL; `pry-byebug` adds stepping. Still common in older codebases.

```ruby
gem "pry-byebug", group: %i[development test]
binding.pry   # drops into Pry; `next`/`step`/`continue`/`finish`, `ls`, `cd obj`, `show-source`
```

Prefer `debug` for new code (no extra dep on modern Ruby, official, faster). Reach for Pry when you want its introspection (`ls`, `show-source`, `cd`).

### irb (modern)

Ruby 3.x ships a vastly upgraded `irb`: multiline editing, autocomplete, syntax highlighting, and a built-in debugger bridge.

```bash
irb                      # autocomplete + colorized
```

```
irb> ls Order            # list methods/constants (Pry-style)
irb> show_source Order#total
irb> edit Order#total    # open in $EDITOR
irb> debug               # hand off to the debug gem mid-session
```

`bin/rails console` uses irb under the hood; `--sandbox` rolls back DB writes on exit.

### Print debugging vs a real debugger

```ruby
puts order            # → to_s, often useless for structured data
p order               # → inspect + returns the value (chainable)
pp order              # pretty-printed, good for nested hashes/arrays
warn "got #{x}"       # → STDERR, won't pollute stdout
```

`p` returns its argument, so you can wrap an expression without changing control flow: `total = p compute_total`.

DO use `p`/`pp` for a quick look. DON'T leave them in committed code (RuboCop's `Lint/Debugger` flags `binding.break`/`pry`; add `Rails/Output` or a custom cop for stray `puts`). For anything non-trivial — wrong values deep in a call stack, conditional state — use `binding.break` instead of sprinkling prints.

### caller / backtrace

```ruby
puts caller                 # array of "file:line:in `method'" for the current stack
puts caller(1, 5)           # skip 1 frame, take 5
rescue => e
  e.backtrace.first(5)      # where it was raised
  e.full_message            # message + class + backtrace, colorized
```

`Thread.current.backtrace` and `caller_locations` (returns `Thread::Backtrace::Location` objects with `#path`, `#lineno`, `#label`) are useful for logging the call site without parsing strings.

### Logger

```ruby
require "logger"
logger = Logger.new($stdout)
logger.level = Logger::INFO
logger.formatter = proc { |sev, time, _prog, msg| "#{time.iso8601} #{sev} #{msg}\n" }

logger.debug("query: #{sql}")   # below level → suppressed
logger.info("processed order %d", order.id)
logger.warn { "expensive #{compute}" }   # block form: only evaluated if level allows
```

Use the block form for expensive messages so the cost is skipped when the level filters them out. In Rails use `Rails.logger` and `Rails.logger.tagged("Orders") { ... }`; configure structured/JSON logging via `config.log_formatter` or the `lograge`/semantic_logger gems. See `references/rails.md`.

## Linting & formatting

### RuboCop

Static analyzer + autocorrector. Configure with `.rubocop.yml`:

```yaml
# .rubocop.yml
require:
  - rubocop-performance
plugins:               # RuboCop 1.72+ prefers `plugins:` over `require:` for extensions
  - rubocop-rails
  - rubocop-rspec

AllCops:
  TargetRubyVersion: 3.4
  NewCops: enable
  Exclude:
    - "db/schema.rb"
    - "vendor/**/*"
    - "bin/**/*"

Style/Documentation:
  Enabled: false

Metrics/MethodLength:
  Max: 15

Layout/LineLength:
  Max: 120
```

Commands:

```bash
bundle exec rubocop                 # lint
bundle exec rubocop -a              # autocorrect SAFE cops only
bundle exec rubocop -A              # autocorrect ALL incl. unsafe — review the diff!
bundle exec rubocop app/models/order.rb   # one file
bundle exec rubocop --only Style/FrozenStringLiteralComment
bundle exec rubocop --format github      # annotations in CI
```

`-a` (safe) won't change behavior; `-A` (aggressive/unsafe) may — always re-run tests after `-A`.

### The TODO file

When adopting RuboCop on an existing codebase, generate a `.rubocop_todo.yml` that grandfathers current offenses so CI passes on day one:

```bash
bundle exec rubocop --auto-gen-config
# creates .rubocop_todo.yml, inherited via inherit_from in .rubocop.yml
```

Then burn it down over time. Regenerate after a big cleanup. Don't hand-disable cops globally to silence them; let the todo track the debt.

### Disabling inline (sparingly)

```ruby
# rubocop:disable Metrics/MethodLength
def big_legacy_method
  ...
end
# rubocop:enable Metrics/MethodLength

result = compute # rubocop:disable Style/SomeCop -- single line, comment why
```

Always re-enable, scope it as narrowly as possible, and add a `--` reason. A whole-file `# rubocop:disable all` is a smell.

### Plugins

- `rubocop-rails` — Rails-aware cops (`pluck` over `map`, `find_each`, time zones).
- `rubocop-rspec` — spec style (`describe` naming, `let` usage, example length).
- `rubocop-performance` — flags slow idioms with faster equivalents.
- `rubocop-rails-omakase` — Rails' own shared config (used by new Rails 8 apps).

### `standard` — zero-config alternative

The `standard` gem wraps RuboCop with a fixed, non-negotiable style (no `.rubocop.yml` bikeshedding).

```bash
gem "standard", group: %i[development test]
bundle exec standardrb          # lint
bundle exec standardrb --fix    # autocorrect
```

Use `standard` when you want to end style debates; use raw RuboCop when you need fine-grained control or the Rails/RSpec/Performance cops (you can still layer `standard` + extensions). Don't run both as competing formatters on the same project.

## Editor / LSP

- **ruby-lsp** (Shopify) — the modern, actively developed language server. Fast, ships an addon API; integrates RuboCop, debugging, and indexing. Preferred default.
- **solargraph** — older LSP; relies on YARD docs and `.solargraph.yml`. Still works, slower indexing.

```bash
gem "ruby-lsp", group: :development, require: false
# VS Code: install the "Ruby LSP" extension; it manages the gem per-project.
```

ruby-lsp reads your `.rubocop.yml` for diagnostics/formatting and uses the bundle's gems. Add `gem "ruby-lsp-rails"` for Rails-aware features (routes, model schema). Keep these in the `Gemfile` (development group) so versions match the project, or use the global install the extension offers.

## Rake

Task runner. Define tasks in `Rakefile` or `lib/tasks/*.rake`.

```ruby
# lib/tasks/data.rake
namespace :data do
  desc "Backfill order totals"
  task backfill: :environment do            # :environment loads Rails
    Order.find_each { |o| o.update!(total: o.recompute_total) }
  end

  desc "Export, depends on backfill"
  task export: %i[backfill] do |_t, args|
    puts "exporting..."
  end
end

# Task with arguments
task :greet, %i[name] => :environment do |_t, args|
  puts "Hello #{args.name || 'world'}"
end
```

```bash
bundle exec rake data:backfill          # run namespaced task
bundle exec rake "data:greet[Ada]"      # pass args (quote for zsh)
bundle exec rake -T                      # list tasks with descriptions (need `desc`)
bundle exec rake -P                      # show prerequisites
```

Prerequisites (`task x: :y`) run once and in dependency order. Only tasks with a `desc` show in `-T`. For anything with real logic, extract to a plain Ruby class and have the task call it — keep tasks thin and testable.

## CI — GitHub Actions matrix

```yaml
# .github/workflows/ci.yml
name: CI
on: [push, pull_request]

jobs:
  test:
    runs-on: ubuntu-latest
    strategy:
      fail-fast: false
      matrix:
        ruby: ["3.2", "3.3", "3.4"]
    services:
      postgres:
        image: postgres:16
        env: { POSTGRES_PASSWORD: postgres }
        ports: ["5432:5432"]
        options: >-
          --health-cmd pg_isready --health-interval 10s
          --health-timeout 5s --health-retries 5
    steps:
      - uses: actions/checkout@v4
      - uses: ruby/setup-ruby@v1
        with:
          ruby-version: ${{ matrix.ruby }}
          bundler-cache: true        # runs bundle install + caches gems
      - run: bundle exec rubocop
      - run: bundle exec rake db:prepare
        env: { DATABASE_URL: postgres://postgres:postgres@localhost:5432/test }
      - run: bundle exec rspec
```

`ruby/setup-ruby` with `bundler-cache: true` installs and caches gems keyed on `Gemfile.lock`. Test the Ruby versions you support (and `head` non-blocking with `continue-on-error` if you want early warning). Run lint as a separate fast job/step so style failures don't block the test signal. See `references/testing.md` for what to run.

## Environment management — dotenv

Keep secrets and per-environment config out of the repo.

```ruby
# Gemfile
gem "dotenv-rails", groups: %i[development test]
```

```bash
# .env  (gitignored!)  — commit a .env.example with blank/placeholder values
DATABASE_URL=postgres://localhost/myapp_dev
STRIPE_KEY=sk_test_xxx
```

```ruby
ENV.fetch("STRIPE_KEY")              # raise if missing — prefer in app code
ENV["STRIPE_KEY"]                    # nil if missing — only when truly optional
```

DO add `.env` (and `.env.local`) to `.gitignore`; commit `.env.example` documenting the keys. DON'T read raw `.env` files in production — use real env vars or Rails encrypted credentials (`bin/rails credentials:edit`, `Rails.application.credentials.stripe[:key]`). See `references/security.md` for secrets handling. Prefer `ENV.fetch("X")` over `ENV["X"]` so a missing var fails loudly at boot, not silently at runtime.

## Reading gem source

```bash
gem which nokogiri          # path to the loaded file: .../nokogiri.rb
bundle show rails           # install path of the bundled rails gem
bundle open activerecord    # open the gem's source in $EDITOR (set EDITOR/BUNDLER_EDITOR)
bundle info rails           # version, summary, path, deps
gem list -d rails           # installed versions + details
gem contents rails          # list files the gem installs
```

`bundle open <gem>` is the fastest way to read exactly the version your app runs (edits there persist until `bundle pristine <gem>` resets it — `bundle pristine` restores any modified gem). Use `gem which` to confirm which file/version actually loaded when there's a conflict.

## Quick checklist

- Commit `Gemfile.lock` for apps; never for libraries.
- Prefer `~>` pessimistic constraints; pin exact only to dodge a known bad version.
- `bundle update <gem>` — never bare `bundle update` to fix one dependency.
- Commit `.ruby-version`; point `Gemfile` at it with `ruby file: ".ruby-version"`.
- One version manager per machine (rbenv/mise/chruby/asdf) — don't mix.
- Use the `debug` gem + `binding.break` for real debugging; `p`/`pp` only for quick looks.
- `rubocop -a` is safe; `rubocop -A` is unsafe — re-run tests after `-A`.
- Adopt RuboCop via `--auto-gen-config` and burn down `.rubocop_todo.yml`; don't disable cops globally.
- Inline `# rubocop:disable` must be narrow, re-enabled, and justified with `--`.
- Use `standard` to kill style debates; raw RuboCop + plugins for fine control.
- ruby-lsp over solargraph for new setups.
- Keep Rake tasks thin; put logic in plain Ruby classes.
- CI: matrix the Ruby versions you support; `ruby/setup-ruby` with `bundler-cache: true`.
- `.env` gitignored + `.env.example` committed; `ENV.fetch` to fail loud; credentials/env vars in prod.
- `bundle open <gem>` / `gem which` to read the exact source you run.
