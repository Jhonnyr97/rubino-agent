# Errors, exceptions & type checking

Modern Ruby (3.2–3.4) error handling, plus optional static typing with RBS and Sorbet. Dense, idiomatic, do/don't.

## The exception hierarchy

```
Exception
├── NoMemoryError, SystemExit, SignalException, ScriptError, ...  # do NOT rescue these
└── StandardError                                                 # rescue THIS
    ├── ArgumentError, TypeError, KeyError, IndexError, NameError
    ├── RuntimeError      # default class for `raise "msg"`
    ├── IOError, Errno::*
    └── your custom errors (subclass StandardError)
```

`rescue` with no class rescues `StandardError`, **not** `Exception`. Rescuing `Exception` swallows `SignalException` (Ctrl-C), `SystemExit` (`exit`), and `NoMemoryError` — breaking process control and hiding fatal bugs.

```ruby
# WRONG — catches Ctrl-C, exit, and out-of-memory; nearly always a bug
begin
  do_work
rescue Exception => e
  log(e)
end

# RIGHT — bare rescue defaults to StandardError
begin
  do_work
rescue => e            # == rescue StandardError => e
  log(e)
end
```

Only rescue what you can handle. Catch specific classes when you can do something specific; let everything else propagate.

```ruby
begin
  parse(payload)
rescue JSON::ParserError => e   # specific: we know how to recover
  fallback
rescue KeyError => e            # specific: missing field
  report_missing(e.key)
end
# Anything else bubbles up — good.
```

## Raising well

```ruby
raise "boom"                          # RuntimeError, message "boom"
raise ArgumentError, "name required"  # class + message — the common form
raise ArgumentError.new("name required")
raise MyError.new(code: 42)           # custom class with structured data
raise                                 # re-raise the current exception (inside rescue)
```

Prefer `raise Class, "message"` over constructing the instance unless you need to pass extra constructor args. Always raise a *class*, never a string-only `raise` for library code where callers may want to rescue a specific type.

`fail` is an alias of `raise`. Some style guides used `fail` for the first raise and `raise` for re-raises; today **prefer `raise` everywhere** for consistency (RuboCop's default `Style/SignalException` enforces `raise`).

## Custom error classes & a per-library base error

Give every library/app a single base error so callers can `rescue MyLib::Error` to catch *anything* from it. Subclass `StandardError`, never `Exception`.

```ruby
module Billing
  class Error < StandardError; end           # base — one per library

  class PaymentDeclined < Error
    attr_reader :code, :gateway_ref

    def initialize(code:, gateway_ref:, message: nil)
      @code = code
      @gateway_ref = gateway_ref
      super(message || "Payment declined (#{code})")
    end
  end

  class RateLimited < Error
    attr_reader :retry_after
    def initialize(retry_after)
      @retry_after = retry_after
      super("Rate limited; retry after #{retry_after}s")
    end
  end
end

# Caller can be coarse or fine-grained:
begin
  Billing.charge(card)
rescue Billing::PaymentDeclined => e
  notify_user(e.code)
rescue Billing::Error => e          # catch-all for this library only
  retry_later(e)
end
```

Rules for custom errors:
- Always call `super(message)` so `#message`/`#to_s` work.
- Expose structured data via `attr_reader`, not by stuffing it into the message string.
- Keep the hierarchy shallow (base + a handful of leaf classes).

## begin / rescue / else / ensure / retry

```ruby
begin
  result = risky
rescue SomeError => e
  handle(e)                 # runs only on error
else
  use(result)              # runs only when NO exception was raised
ensure
  cleanup                  # ALWAYS runs (success, error, return, or break)
end
```

- `else` holds the "happy path" code that must *not* be guarded by the rescue. Keeps the `begin` block to just the risky call.
- `ensure` always runs — use it for cleanup. Do **not** `return` from `ensure`; it silently swallows the in-flight exception/return value.

```ruby
# WRONG — return in ensure eats the exception
def f
  raise "x"
ensure
  return 1   # caller gets 1, exception vanishes. Never do this.
end
```

### Method-level rescue (no explicit begin)

`def`, blocks, and `do...end` have implicit begin/ensure scopes:

```ruby
def fetch
  api_call
rescue Timeout::Error => e
  retry_or_raise(e)
ensure
  close_connection
end
```

### retry with a backoff cap

`retry` re-runs the `begin` block. **Always cap attempts** or you get infinite loops. Add backoff (ideally with jitter) for network calls.

```ruby
def with_retries(max: 3, base: 0.5)
  attempts = 0
  begin
    yield
  rescue Net::OpenTimeout, Net::ReadTimeout => e
    attempts += 1
    raise if attempts >= max                 # give up — re-raise last error
    sleep(base * (2 ** (attempts - 1)) + rand * 0.1)  # exp backoff + jitter
    retry
  end
end

with_retries(max: 4) { http.get(url) }
```

Do **not** `retry` on programmer errors (`ArgumentError`, `NoMethodError`) — they won't fix themselves. Only retry transient failures.

## Rescue modifier & inline-rescue pitfalls

The one-line `expr rescue fallback` form catches **`StandardError`** and discards the exception object. It's a blunt instrument.

```ruby
value = Integer(str) rescue 0      # ok-ish: narrow, intentional fallback
```

Pitfalls:
- It hides *every* `StandardError`, not just the one you expect (e.g. a typo `NameError` becomes `0`).
- You can't inspect the error.
- It's easy to over-scope.

```ruby
# WRONG — masks bugs; if `parse` raises NoMethodError you silently get nil
data = parse(payload) rescue nil

# RIGHT — name the error you actually expect
data =
  begin
    parse(payload)
  rescue JSON::ParserError
    nil
  end
```

For "give me nil on a known failure", prefer purpose-built methods: `Integer(s, exception: false)`, `Float(s, exception: false)`, `hash.dig`, `Array.fetch` with default, etc.

```ruby
Integer("x", exception: false)   # => nil, no rescue needed
```

## Inspecting the rescued exception

```ruby
rescue => e
  e.message        # the message string
  e.class          # e.g. KeyError
  e.backtrace      # Array<String>
  e.full_message   # formatted message + backtrace + cause chain (great for logs)
  e.cause          # the exception that was in flight when this one was raised
```

`e.full_message(highlight: false)` gives plain text suited for log files; `highlight: true` (default on a TTY) adds ANSI color.

## Cause chaining (`Exception#cause`)

When you `raise` *inside* a `rescue`, Ruby automatically sets the new exception's `#cause` to the one being handled — preserving the original. Do **not** manually thread the original through unless you want to override it.

```ruby
def load_config
  YAML.safe_load_file(path)
rescue Psych::SyntaxError => e
  raise ConfigError, "config #{path} is invalid"
  # e becomes the implicit cause; full_message shows both
end
```

`full_message` then prints:

```
ConfigError: config /etc/app.yml is invalid
  ...
caused by: Psych::SyntaxError: (...) ...
```

Override or suppress the implicit cause explicitly:

```ruby
raise ConfigError, "bad config", cause: nil          # drop the chain
raise ConfigError.new("bad config"), cause: original # set a specific cause
```

Wrap low-level errors in your library's error type while keeping the cause, so callers get a stable interface and you don't lose the root cause:

```ruby
rescue PG::Error => e
  raise Repo::DatabaseError, "query failed"   # cause = the PG error, preserved
```

## Resource cleanup: prefer auto-closing blocks over manual ensure

If an API offers a block form that closes/releases automatically, use it. Reach for `ensure` only when there's no block form.

```ruby
# RIGHT — block form closes the file even on exception
File.open(path, "r") do |f|
  process(f)
end

# Manual equivalent — only when no block form exists
f = acquire_resource
begin
  process(f)
ensure
  f.release    # runs on success and on error
end
```

Common block-closing APIs: `File.open`, `Tempfile.create`, `Net::HTTP.start`, `Mutex#synchronize`, `connection_pool.with`, `ActiveRecord::Base.transaction` (rolls back on raise). Don't hand-roll `ensure` when one of these fits.

## Structured error data & custom messages

Put machine-readable detail in attributes; keep the message human-readable.

```ruby
class ValidationError < StandardError
  attr_reader :errors  # e.g. { email: ["is invalid"], age: ["too low"] }

  def initialize(errors)
    @errors = errors
    super("Validation failed: #{errors.keys.join(', ')}")
  end
end

begin
  validate!(form)
rescue ValidationError => e
  render json: e.errors, status: :unprocessable_entity
end
```

This is cleaner than parsing strings out of `e.message`, and it survives i18n of the message.

## Exceptions vs Result objects

Use **exceptions** for genuinely exceptional / unexpected conditions and for cross-cutting failures you want to bubble up (DB down, bug, programmer error). Use a **Result object** when failure is an expected, *modeled* outcome that the caller must branch on (validation, "user not found", payment declined in a flow). Don't use exceptions for ordinary control flow — they're slow on the raise path and obscure intent.

```ruby
# Exception: unexpected
raise Repo::DatabaseError if conn.dead?

# Result: expected branch the caller handles
result = ChargeCard.call(card)
if result.success?
  render :receipt
else
  render :declined, locals: { reason: result.error }
end
```

Result/Either object design, `.success?`/`.failure?` shapes, and the `dry-monads` approach are covered in **See references/oo-design.md**. Testing that code raises (`raise_error` matcher, etc.) is in **See references/testing.md**.

## Warnings & deprecations

`warn` writes to `$stderr` (suppressed by `-W0` / `$VERBOSE = nil`). Use it for non-fatal advisories.

```ruby
warn "[MyLib] #{old} is deprecated; use #{new}", category: :deprecated
```

`category: :deprecated` (Ruby 3.0+) lets users filter: `Warning[:deprecated] = false` silences deprecation warnings globally. Gate noisy ones behind it.

Intercept/route warnings (e.g. to your logger, or to fail tests on warnings) via the `Warning` module:

```ruby
module Warning
  def self.warn(msg, category: nil)
    Rails.logger.warn(msg)   # or: raise in test env to surface them
  end
end
```

Rails: prefer `ActiveSupport::Deprecation` instances for library-style deprecations so behavior, horizon, and silencing are configurable:

```ruby
DEPRECATOR = ActiveSupport::Deprecation.new("2.0", "MyGem")
def old_api(*) = DEPRECATOR.warn("old_api is deprecated; use new_api") || new_api(*)
```

---

# Type checking (optional)

Ruby is dynamically typed; static typing is **opt-in** and additive. Two ecosystems: **RBS + Steep** (official, separate sig files) and **Sorbet** (inline `sig`, runtime + static). They don't mix per-file; pick one per project.

## RBS + Steep

RBS is Ruby's standard type-signature language. Signatures live in separate `.rbs` files (typically under `sig/`). `steep` is the type checker; `rbs collection` manages third-party signatures.

```rbs
# sig/billing.rbs
module Billing
  class PaymentDeclined < StandardError
    attr_reader code: Integer
    attr_reader gateway_ref: String
    def initialize: (code: Integer, gateway_ref: String, ?message: String?) -> void
  end

  def self.charge: (Card) -> Result
end
```

```ruby
# Steepfile
target :app do
  signature "sig"
  check "lib"
  # library "json", "logger"   # pull in stdlib sigs
end
```

```bash
gem install rbs steep
rbs collection init        # creates rbs_collection.yaml (gem_rbs_collection)
rbs collection install     # vendors third-party .rbs into .gem_rbs_collection
steep check                # type-check the project
rbs prototype rb lib/x.rb  # scaffold an initial .rbs from existing code
```

Pros: official, no runtime cost, no source pollution, gradual. Cons: signatures live apart from code (can drift), tooling/editor support less mature than Sorbet, inference is weaker.

## Inline RBS comments (Ruby 3.x)

Ruby 3.x (with RBS 3.x / Steep) supports type annotations as **special comments** next to the code, so signatures sit beside implementation without a separate file:

```ruby
# @rbs name: String
# @rbs return: Integer
def length_of(name)
  name.length
end

xs = [] #: Array[String]
config = fetch #: Config
```

This is a pragmatic middle ground: keeps types near code while staying valid Ruby (they're comments). Steep reads them. Good for incremental adoption.

## Sorbet

Sorbet uses inline `sig` blocks plus `T.*` helpers, and checks both **statically** (`srb tc`) and **at runtime** (the `sig` enforces types when the method runs, raising `TypeError` on violation).

```ruby
# typed: true
require "sorbet-runtime"

class Box
  extend T::Sig

  sig { params(value: Integer).returns(String) }
  def label(value)
    "##{value}"
  end

  sig { void }
  def initialize
    @items = T.let([], T::Array[String])   # declare ivar type
  end
end
```

```bash
gem install sorbet sorbet-runtime
srb init       # generates sorbet/ + RBI files for gems
srb tc         # static type check
```

- `# typed: false | true | strict | strong` sigil per file controls strictness.
- `T.let`, `T.cast`, `T.must` (assert non-nil), `T.nilable(X)`, `T.any(A, B)`, `T.untyped`.
- RBI files (`.rbi`) describe gems/Rails; `tapioca` generates them.

Pros: mature IDE support, runtime enforcement catches violations in tests, strong inference. Cons: runtime overhead from `sig` checks, source is more verbose / Sorbet-specific, RBI maintenance, `T.untyped` escape hatches erode guarantees.

## When typing pays off — tradeoffs

Worth it:
- Large/long-lived codebases and libraries with many callers (signatures = enforced docs).
- Public gem APIs — ship `.rbs` so consumers get checking.
- Refactors across big surfaces; catching `nil` and arity errors before runtime.

Skip / defer:
- Small scripts, spikes, short-lived code — overhead outweighs benefit.
- Highly metaprogrammed code (`method_missing`, dynamic `define_method`) — hard to type; needs manual sigs and often `T.untyped`. See references/metaprogramming.md.

Guidance: start `# typed: false`/loose, type the **boundaries** (public methods, models, service `#call`) first, tighten incrementally. Don't let `T.untyped`/`T.must` proliferate — each one is an unchecked hole. Types complement tests; they don't replace them (See references/testing.md).

## Quick checklist

- `rescue` (bare) == `rescue StandardError`. **Never `rescue Exception`** in normal code.
- Rescue the **most specific** class you can actually handle; let the rest propagate.
- `raise Class, "message"` is the default form; raise classes, not strings, in libraries.
- Give each library one base error subclassing `StandardError`; keep the hierarchy shallow.
- Put structured detail in `attr_reader`s; keep `#message` human-readable.
- Always `super(message)` in custom error `initialize`.
- Cap `retry` with a max-attempt count and exponential backoff + jitter; only retry transient errors.
- Never `return` from `ensure`. Use `else` for the happy path.
- Prefer block-closing APIs (`File.open { }`, `transaction { }`) over manual `ensure`.
- Avoid `expr rescue fallback` for anything but narrow, intentional fallbacks; prefer `Integer(s, exception: false)` & friends.
- Re-raising inside `rescue` sets `#cause` automatically — wrap low-level errors in your type without losing the root.
- Log with `e.full_message`; it includes the cause chain.
- Use `fail`? No — prefer `raise` everywhere.
- Exceptions for the unexpected; Result objects for expected, branchable failures (See references/oo-design.md).
- `warn(..., category: :deprecated)`; route via `Warning.warn`; use `ActiveSupport::Deprecation` in Rails.
- Typing: RBS+Steep (official, separate sigs, inline `#:` comments) or Sorbet (`sig`, runtime+static). Type boundaries first; minimize `T.untyped`.
