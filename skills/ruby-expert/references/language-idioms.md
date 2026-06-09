# Ruby language & core idioms

Modern Ruby (3.2–3.4) fundamentals. Dense, idiomatic, do/don't. For metaprogramming see `references/metaprogramming.md`; OO design see `references/oo-design.md`; exceptions see `references/errors-and-types.md`; concurrency see `references/concurrency.md`.

## Truthiness & nil

Only `false` and `nil` are falsey. `0`, `""`, `[]`, `{}` are all **truthy**.

```ruby
if count          # true even when count == 0
if count.positive? # what you usually meant
if list.any?       # not `if list` — empty array is truthy
```

Distinguish "missing" from "falsey value". `||` collapses both `nil` and `false`; use `nil?` / `key?` when `false` is a legitimate value.

```ruby
flag = opts[:enabled] || true   # WRONG: explicit false becomes true
flag = opts.fetch(:enabled, true) # RIGHT: only defaults when key absent
```

### Safe navigation `&.`

`&.` short-circuits on `nil` only. It does **not** guard against other return values.

```ruby
user&.address&.city          # nil if any link is nil
config&.fetch(:host)         # still raises if config present but key missing

# DON'T chain &. to paper over a design smell (Law of Demeter — see oo-design.md).
# DON'T mix with ||: `a &. b || c` parses as `(a&.b) || c` — usually fine, but be explicit.
```

`&.` differs from `try` (Rails): `&.` calls the method and raises NoMethodError if the receiver is non-nil but doesn't respond; `try` swallows that. Prefer `&.`.

### `||=`, `&&=`

```ruby
@cache ||= compute        # memoize (NOT thread-safe — see performance.md / concurrency.md)
h[:k] ||= []              # default-then-append; for hashes prefer Hash.new { |h,k| h[k] = [] }
config &&= config.dup     # reassign only if already truthy
```

`||=` on a falsey-but-valid value recomputes every time. If `compute` can return `false`/`nil`, memoize with a sentinel:

```ruby
@result = compute unless defined?(@result)
```

## Symbols vs strings

Symbols are immutable, interned, identity-comparable — use them as **identifiers/keys**. Strings are for **data/text**.

```ruby
status == :active        # state/identifier -> symbol
record.name == "Acme"    # human data -> string
```

Don't `to_sym` untrusted/unbounded input in long-lived processes (symbols from user input are GC'd since 2.2, but still avoid for clarity/security — see security.md).

### Frozen string literals

Put this **magic comment** on line 1 of every file (it must be the first line, or after `#!`):

```ruby
# frozen_string_literal: true
```

All string literals in the file become frozen → fewer allocations (see performance.md), and accidental mutation raises. When you need a mutable buffer, allocate explicitly:

```ruby
buf = +""        # unary + = dup'd, mutable string
buf << "a" << "b"
name = -"active" # unary - = frozen/deduplicated
```

### String building

```ruby
# DON'T build with repeated + in a loop (O(n²) allocations)
out = ""; items.each { |i| out = out + i.to_s }   # BAD

# DO use << (mutating) or join
out = +""; items.each { |i| out << i.to_s }
out = items.map(&:to_s).join(", ")
out = "#{name} (#{count})"     # interpolation > concatenation
out = format("%.2f%%", pct)    # format/sprintf for padding/precision
```

`<<` mutates left operand; `+` allocates a new string. Heredocs with `<<~` strip leading indentation:

```ruby
sql = <<~SQL
  SELECT *
  FROM users
SQL
```

## Method arguments

### Keyword arguments (Ruby 3.x keeps them fully separate from positionals)

```ruby
def connect(host:, port: 5432, **opts)   # host required, port optional, rest in opts
  ...
end
connect(host: "db", timeout: 5)          # timeout lands in opts
```

- `name:` (no default) = required keyword.
- `name: default` = optional.
- `**opts` = collect extra keywords; `**nil` forbids any keywords.
- Prefer keyword args when a method takes 3+ params or any boolean flag (avoids mystery `true, false, nil` call sites).

```ruby
render(partial, true, false)              # DON'T: unreadable
render(partial, layout: true, cache: false) # DO
```

Splatting a hash into keywords needs explicit `**` in 3.x:

```ruby
opts = { host: "db", port: 5432 }
connect(**opts)            # required; bare `connect(opts)` raises ArgumentError
```

### Argument forwarding `...`

Forward all args (positional, keyword, block, and 3.2+ anonymous splats) verbatim:

```ruby
def log_and_call(...)
  logger.info("calling")
  target.call(...)
end
```

Ruby 3.2 also allows anonymous `*`, `**`, `&` forwarding:

```ruby
def wrap(*, **, &) = inner(*, **, &)
```

## Blocks, procs, lambdas

```ruby
[1,2,3].each { |n| puts n }        # block — not an object, passed implicitly
sq = ->(n) { n * n }               # lambda (stabby)
pr = proc { |n| n * n }            # proc
```

### Return semantics (the key difference)

- **lambda**: `return` returns from the lambda; strict arity.
- **proc / block**: `return` returns from the **enclosing method**; lenient arity (missing args → nil, extra ignored).

```ruby
def find_first(list)
  list.each { |x| return x if x.positive? }  # block return -> exits find_first ✔
end

def m
  p = proc { return 42 }
  p.call            # returns from m
  99                # never reached
end
# DON'T store a proc and call it later expecting local return — it LocalJumpErrors once m has returned.
```

Prefer lambdas for stored callables (predictable return + arity checking).

### yield, block_given?, &block

```ruby
def each_pair
  return enum_for(:each_pair) unless block_given?  # return Enumerator if no block
  yield :a, 1
  yield :b, 2
end

def with_capture(&block)   # capture only when you must pass it on / store it
  block.call(self)
end
```

`yield` is faster than `&block` + `block.call` (no Proc allocation). Capture with `&block` only when forwarding or storing it.

### Symbol#to_proc and method references

```ruby
%w[a b].map(&:upcase)          # &:sym -> ->(x){ x.upcase }
[1,-2].map(&:abs)
nums.map(&method(:format_row)) # method object as block
```

## Enumerable toolbox — pick the right tool

```ruby
map        # transform 1:1
flat_map   # map then flatten one level  (map+flatten -> flat_map)
filter_map # map + compact + select in one pass (3.x); great for "transform then drop nils"
select / filter   # keep matching     reject # drop matching
each_with_object   # build a collection; returns the object (not the block value)
reduce / inject    # fold to single value
sum                # numeric/string fold (sum(0.0) to start as float)
tally              # frequency Hash {elem => count}
group_by           # Hash {key => [elems]}
partition          # [matching, non_matching]
chunk_while / slice_when  # split into runs by adjacent-pair predicate
each_slice(n)      # fixed-size batches  each_cons(n) # sliding windows
zip                # interleave/pair parallel collections
min_by/max_by/sort_by/minmax_by  # by derived key (computed once via Schwartzian)
find / detect      # first match
```

```ruby
# filter_map vs map+compact
emails = users.filter_map { |u| u.email if u.active? }   # one pass ✔
emails = users.map { |u| u.email if u.active? }.compact   # two passes ✗

# each_with_object vs reduce for building
index = items.each_with_object({}) { |i, h| h[i.id] = i }      # clean
index = items.reduce({}) { |h, i| h[i.id] = i; h }             # must return h — error-prone

# counting -> tally, not manual hash
%w[a b a].tally            # {"a"=>2, "b"=>1}

# grouped sums
totals = orders.group_by(&:user_id).transform_values { |os| os.sum(&:amount) }
```

`sort_by`/`max_by` compute the key once per element — prefer over `sort { |a,b| f(a) <=> f(b) }` when the key is expensive. Use `sort`/`<=>` block only for multi-key or mixed-direction sorts:

```ruby
people.sort_by { |p| [p.last, p.first] }       # multi-key ascending
people.sort_by { |p| [-p.age, p.name] }        # age desc, name asc (negate numeric key)
```

### Lazy enumerators (large/infinite/streaming)

`lazy` defers and pipelines per-element — no giant intermediate arrays. Essential for files and infinite ranges.

```ruby
(1..Float::INFINITY).lazy.select(&:even?).first(5)   # [2,4,6,8,10]

File.foreach("huge.log").lazy
    .map(&:chomp)
    .select { |l| l.include?("ERROR") }
    .first(100)        # stops reading after 100 matches
```

Call a terminal op (`first`, `to_a`, `force`, `each`) to materialize. DON'T `.lazy` short in-memory arrays — overhead outweighs benefit.

## Comparable & Enumerable mixins on your own classes

Define `<=>` (returns -1/0/1/nil) and include `Comparable` to get `< <= == > >= between? clamp`:

```ruby
class Version
  include Comparable
  attr_reader :parts
  def initialize(str) = @parts = str.split(".").map(&:to_i)
  def <=>(other) = parts <=> other.parts   # Array#<=> compares elementwise
end
Version.new("1.2.0") < Version.new("1.10.0")  # => true
```

Define `each` and include `Enumerable` to get the whole toolbox above:

```ruby
class Roster
  include Enumerable
  def initialize(members) = @members = members
  def each(&block) = @members.each(&block)   # yield each element
end
Roster.new(people).map(&:name).sort          # map/select/sort_by all work now
```

## Pattern matching (`case/in`)

Structural matching with binding. `in` raises `NoMatchingPatternError` if nothing matches (use `else` to handle). Use `case/in` for shape; `case/when` for simple equality.

```ruby
case response
in { status: 200, body: }                 # binds body
  body
in { status: 404 }
  raise NotFound
in { status: Integer => code } if code >= 500
  retry_later(code)
else
  raise "unexpected"
end
```

Array, find, and alternative patterns:

```ruby
case command
in [:move, Integer => x, Integer => y]     # array pattern, type + bind
  move(x, y)
in [:say, *words]                          # splat captures rest
  say(words.join(" "))
in [*, {error:}, *]                        # find pattern: locate elem anywhere
  fail error
in :start | :resume                        # alternative pattern
  begin!
end
```

One-line `=>` (rightward assignment / destructuring) and `in` as a boolean test:

```ruby
config => { host:, port: }                 # raises if no match; binds host, port
record in { id: Integer }                  # => true/false, no raise
```

### deconstruct / deconstruct_keys

Make your objects matchable. Array patterns call `deconstruct`; hash patterns call `deconstruct_keys(keys)`. `Data` and `Struct` implement both automatically.

```ruby
Point = Data.define(:x, :y)
case Point.new(1, 2)
in [x, y] then ...        # via deconstruct
in { x:, y: } then ...    # via deconstruct_keys
end
```

## Struct vs Data.define

Use **`Data.define`** (Ruby 3.2+) for immutable value objects — the modern default. Use `Struct` only when you need mutability or backward compat.

```ruby
Point = Data.define(:x, :y) do
  def dist = Math.hypot(x, y)
end
p = Point.new(x: 1, y: 2)      # or Point.new(1, 2)
p.with(y: 9)                   # returns a NEW Point (copy-with-change)
p.x = 0                        # NoMethodError — frozen, no setters ✔
```

- `Data`: immutable, no setters, value `==`, `deconstruct`/`deconstruct_keys`, `#with`. Ideal for DTOs/value objects (see oo-design.md).
- `Struct`: mutable (`s.x = 1`), positional **or** `keyword_init: true`. Pick one and be consistent.

```ruby
Mutable = Struct.new(:x, :y, keyword_init: true)   # always pass keyword_init explicitly
```

DON'T use `OpenStruct` — slow, defeats method-missing safety, allocations galore.

## Hash idioms

```ruby
h.fetch(:k)                 # raises KeyError if missing — use when key MUST exist
h.fetch(:k, default)        # default value
h.fetch(:k) { expensive }   # block form — default computed only if needed
h[:k]                       # returns nil if missing (can't tell missing from nil value)

h.dig(:a, :b, :c)           # safe nested access; nil if any level missing
data.dig(:users, 0, :name)  # works across Hash/Array

Hash.new(0)                 # default value 0 (SHARED — don't use mutable default!)
Hash.new { |hash, key| hash[key] = [] }   # default BLOCK — fresh array per key ✔

counts = Hash.new(0); words.each { |w| counts[w] += 1 }   # or just words.tally

h.transform_values { |v| v * 2 }
h.transform_keys(&:to_sym)
h.filter_map { |k, v| [k, v] if v }   # works on hashes too
h.slice(:a, :b)  /  h.except(:c)
h1.merge(h2) { |key, old, new| old + new }   # block resolves conflicts
```

```ruby
Hash.new([]).tap { |h| h[:a] << 1 }   # BUG: every key shares ONE array
Hash.new { |h,k| h[k] = [] }          # correct
```

## Syntax niceties

### Endless methods (Ruby 3.0+)

```ruby
def square(n) = n * n
def full_name = "#{first} #{last}"
def active? = status == :active
```

Use for true one-liners (no `begin`/multi-statement). Keep the `= expr` on one logical line.

### Numbered & `it` block params

```ruby
[1,2,3].map { _1 * 2 }          # _1.._9 numbered params (2.7+)
pairs.each { puts "#{_1}=#{_2}" }
[1,2,3].map { it * 2 }          # `it` = single implicit param (Ruby 3.4)
```

Prefer named params for anything non-trivial or nested (you can't use `_1` across nesting levels cleanly). `it`/`_1` shine for short single-arg blocks.

### Range tricks

```ruby
(1..5)        # inclusive   (1...5) # exclusive end
(1..)         # beginless/endless ranges
arr[2..]      # from index 2 to end
arr[..3]      # up to index 3
("a".."e").to_a
(1..10).step(2).to_a
case score
in 90.. then "A"          # endless range in pattern
in 80...90 then "B"
end
(Time.now..).cover?(t)    # ranges as predicates via cover?/include?
```

## Numbers & money

`Float` is binary floating point — **never** use it for money or exact decimals.

```ruby
0.1 + 0.2 == 0.3          # => false  (0.30000000000000004)
```

Use `BigDecimal` (from `require "bigdecimal"`/`"bigdecimal/util"`) for currency:

```ruby
require "bigdecimal"
require "bigdecimal/util"

price = "19.99".to_d           # BigDecimal, exact
total = price * 3              # 59.97 exact
BigDecimal("0.1") + BigDecimal("0.2") == BigDecimal("0.3")   # => true

# DON'T construct BigDecimal from a Float — you inherit the float error:
BigDecimal(0.1, 10)            # BAD-ish; use the string: BigDecimal("0.1")
```

Better: store money as **integer cents** and format on display. `Rational` gives exact fractions; `Integer` is arbitrary precision (no overflow). Divide carefully:

```ruby
7 / 2        # => 3   (integer division, truncates)
7.0 / 2      # => 3.5
7.fdiv(2)    # => 3.5  (explicit float division)
Rational(7, 2)        # => (7/2) exact
(0.30 * 100).round   # float rounding lands you in trouble; round BigDecimal/cents instead
```

For rounding modes use `BigDecimal#round(2, :half_up)` etc.; default Ruby `Float#round` is round-half-to-even-ish — be explicit for financial math.

## Quick checklist

- Add `# frozen_string_literal: true` to line 1 of every file; build with `<<`/`join`, allocate mutable with `+""`.
- Only `nil`/`false` are falsey; use `fetch` (not `||`) when `false`/`nil` is a valid value.
- Symbols = identifiers/keys; strings = data. Don't `to_sym` untrusted input.
- Keyword args for 3+ params or any boolean flag; splat hashes with `**`; forward with `...`.
- Lambdas for stored callables (strict arity, local `return`); `yield` over `&block` unless you must capture.
- `filter_map`, `each_with_object`, `tally`, `group_by`, `sort_by`/`min_by`/`max_by` over manual loops; `.lazy` for huge/infinite/streamed data.
- `include Comparable` (+`<=>`) and `include Enumerable` (+`each`) to enrich your own classes.
- `case/in` for structure; bind with `{ key: }`, `=>`, guards; `else` to avoid NoMatchingPatternError.
- `Data.define` for immutable value objects; `Struct` only when mutable; never `OpenStruct`.
- `fetch`/`dig`/`transform_values`; `Hash.new { |h,k| h[k] = [] }` (block, not shared mutable default).
- Endless `def x = ...` for one-liners; `it`/`_1` for short single-arg blocks.
- Money: `BigDecimal("...")` from strings or integer cents — never `Float`; `fdiv`/`Rational` to avoid integer-division surprises.
