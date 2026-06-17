---
name: ruby-expert
description: Deep Ruby & Rails expertise — idioms, OO design, metaprogramming, errors/types, concurrency, Rails, testing, performance, security, tooling, gem authoring. Load when writing, reviewing, debugging, or designing Ruby or Rails code, or when a Ruby/Rails decision needs an authoritative answer.
languages: [ruby]
---

# Ruby expert

Authoritative, current (Ruby 3.2–3.4, Rails 7.1–8.x) knowledge for writing,
reviewing, and designing idiomatic Ruby. This file is the router: it carries the
non-negotiable defaults, then points you at one bundled reference for deep,
task-specific guidance. **Load the matching reference before answering a
non-trivial question in that area** — don't work from memory when a reference
covers it.

## Non-negotiable defaults

Apply these unless the surrounding project clearly does otherwise (existing
project conventions always win over these defaults):

- **Match the codebase first.** Read neighbouring files and mirror their naming,
  structure, and idioms before introducing your own. Consistency beats personal
  preference.
- **`# frozen_string_literal: true`** as the first line of every Ruby source file.
- **Naming:** `snake_case` for methods/variables, `CamelCase` for classes/modules,
  `SCREAMING_SNAKE_CASE` for constants, `?` suffix for predicates, `!` suffix only
  for the dangerous/mutating variant that has a safe sibling.
- **Keyword arguments** for anything with more than one or two parameters, or any
  boolean/optional flag — never a positional boolean.
- **`rescue StandardError`**, never a bare `rescue` or `rescue Exception`. Never
  rescue just to swallow — handle, re-raise, or don't rescue.
- **Two-space indentation, no tabs.** Guard clauses over deep nesting. Prefer the
  smallest method that reads clearly.
- **Tests are part of "done."** New behavior ships with a spec; a bug fix ships
  with the regression test that would have caught it.
- **Run the linter.** Honor the project's `.rubocop.yml` / `standard`; don't fight
  it or disable cops without a reason in a comment.
- **Security is not optional.** Never interpolate untrusted input into SQL, shell,
  `eval`, `send`, or deserialization. See `references/security.md`.

## Which reference to load

| Load `references/…` | When the task involves |
| --- | --- |
| `language-idioms.md` | Day-to-day Ruby: collections/Enumerable, pattern matching, blocks/procs/lambdas, keyword args, `Data`/`Struct`, hash idioms, nil handling, numbers/money |
| `datetime-and-encoding.md` | Dates/times/time zones (the `Time.now` vs `Time.zone.now` footgun, DST, parsing, monotonic clock) and string encoding (UTF-8, `force_encoding` vs `encode`, scrubbing bad bytes) |
| `metaprogramming.md` | `define_method`, `method_missing`, `send`, hooks, `class_eval`, refinements, building DSLs, introspection |
| `oo-design.md` | Class/module design, SOLID, composition vs inheritance, service/value/query/policy objects, Result objects, dependency injection, refactoring a god object |
| `errors-and-types.md` | Exception design, `rescue`/`retry`/`ensure`, custom errors, cause chaining, and RBS/Sorbet type checking |
| `concurrency.md` | Threads, mutexes/queues, the GVL, fibers, the `async` gem, Ractors, processes/fork — choosing a concurrency model |
| `rails.md` | Anything Rails: Active Record, migrations, controllers, routing, concerns, jobs, Hotwire, caching, Rails secure defaults |
| `testing.md` | RSpec or Minitest, FactoryBot, TDD, doubles/mocks, WebMock/VCR, request vs system specs, fixing flaky tests |
| `performance.md` | Profiling, memory/allocations, GC, YJIT, fixing a slow path or high-memory process |
| `security.md` | Injection (SQL/command/eval), mass assignment, deserialization, XSS/CSRF, authz/IDOR, secrets, Brakeman, dependency audit, ReDoS |
| `tooling.md` | Bundler, version managers (rbenv/asdf/mise/rv), the `debug` gem/pry, RuboCop/standard, Rake, CI, LSP |
| `gem-authoring.md` | Building or releasing a gem: gemspec, Zeitwerk, versioning/CHANGELOG, `rake release`, shipping assets |

When a task spans areas (e.g. "make this Rails query fast and safe"), load each
relevant reference. Each reference ends with a `## Quick checklist` you can scan
for the rules without re-reading the whole file.

## How to apply

1. Identify the area(s) the task touches and load the matching reference(s) above.
2. Inspect the actual project (Gemfile, `.rubocop.yml`, existing code) — its
   conventions override the generic defaults here.
3. Write the change, then verify it: run the tests and the linter before calling
   it done.
