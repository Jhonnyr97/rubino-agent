# Contributing to rubino

Thanks for helping improve rubino. This is the dev setup, test, and release flow.

## Development setup

Requirements: Ruby 3.3.3 (see `.ruby-version` / `mise.toml`; the gem supports >= 3.1) and SQLite3.

```bash
git clone https://github.com/Jhonnyr97/rubino-agent.git
cd rubino-agent
bundle install
bundle exec rubino setup     # config + database in your home (or set RUBINO_HOME)
bundle exec rubino doctor     # verify
```

Run the CLI from the checkout with `bundle exec rubino <command>`.

> Tip: point `RUBINO_HOME` at a throwaway directory while developing so you don't touch your real `~/.rubino`. For LLM-free work, use the fake provider (`model.default: fake/happy-path` + `RUBINO_ALLOW_FAKE=1`).

## Tests

```bash
bundle exec rspec                 # full suite (sequential; generates the coverage report)
bundle exec rspec path/to/file_spec.rb
bundle exec rake                  # default task == spec
bundle exec rake parallel:spec    # full suite across all CPU cores (no coverage report)
bundle exec rake parallel:spec[4] # ...forced to 4 workers
```

`parallel:spec` shards the suite across one process per core via the
`parallel_tests` gem; each worker is isolated by `TEST_ENV_NUMBER`
(per-worker `RUBINO_HOME`, document fixtures, and example-status file).
SimpleCov is skipped under parallel runs (the workers would race the
coverage resultset) — use the sequential `bundle exec rspec` when you need
the coverage report.

The HTTP boundary is locked by an end-to-end contract suite under `spec/rubino/api/contract/`. When the docs and the contract suite disagree, **the contract suite is canonical** — update the docs to match.

## Lint

```bash
bundle exec rubocop               # rubocop + rubocop-rspec
bundle exec rubocop -A            # autocorrect
```

## Pull requests

- Branch off `main`; keep changes focused.
- Add or update specs for behavior changes; touch tests only for what you change.
- Run `bundle exec rspec` and `bundle exec rubocop` before opening the PR.
- Update the relevant docs. The slash-command list (`docs/commands.md`) is sourced from `lib/rubino/commands/built_ins.rb` and the config reference (`docs/configuration.md`) from `lib/rubino/config/defaults.rb` — keep them in sync with code.
- Add a `CHANGELOG.md` entry (the project follows [keep-a-changelog](https://keepachangelog.com/)).

## Anti-drift: single sources of truth

These enumerations live in code; docs must read from them, not duplicate them by hand:

- Slash commands ← `BuiltIns::DESCRIPTIONS` (also drives `/help` and tab-completion).
- Config keys & defaults ← `Config::Defaults::MODULE_DEFAULTS` (rich inline comments are the descriptions; `Defaults.to_yaml` dumps a commented YAML).
- Built-in tools ← `Tools::Registry#register_defaults!`.

## Releasing

The gem version lives in `lib/rubino/version.rb`. Standard Bundler gem tasks are wired (`require "bundler/gem_tasks"`):

```bash
# 1. bump lib/rubino/version.rb
# 2. update CHANGELOG.md (move Unreleased -> the new version)
# 3. build + tag + push the gem:
bundle exec rake release
```

`rake release` builds the gem, creates the version git tag, pushes commits and the tag, and pushes the `.gem` to the configured host.

## Architecture

See [docs/architecture.md](docs/architecture.md) and [AGENTS.md](AGENTS.md) for the layer diagram and the core loop overview.
