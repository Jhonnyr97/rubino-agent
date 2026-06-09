# Performance & memory

Making Ruby (3.2–3.4) and Rails (7.1–8.x) fast and lean. **Golden loop: profile → fix the single biggest cost → re-measure.** Never optimize on a hunch; Ruby's hotspots are routinely counter-intuitive (allocation and GC, not arithmetic).

## Measure first

Do not micro-optimize without data. A "faster" expression that runs 1% of the time is worthless. Find where the wall-clock and allocations actually go, then act.

### Benchmark / benchmark-ips

`Benchmark` (stdlib) gives raw timings; **`benchmark-ips`** (gem) is the right tool for *comparing implementations* — it warms up, runs to a stable iteration rate, and reports a relative comparison with error bars.

```ruby
require "benchmark/ips"

ARR = (1..10_000).to_a

Benchmark.ips do |x|
  x.report("map+compact") { ARR.map { |n| n if n.even? }.compact }
  x.report("filter_map")  { ARR.filter_map { |n| n if n.even? } }
  x.report("select+map")  { ARR.select(&:even?).map { |n| n } }
  x.compare!  # prints "filter_map: 1.42x faster" etc.
end
```

Rules:
- Always `compare!` — absolute ips numbers are meaningless across machines.
- Put real-sized data in the benchmark; tiny inputs hide allocation/GC cost.
- For allocation comparisons, pair ips with `memory_profiler` (below) — CPU and memory rankings often disagree.

```ruby
# WRONG: timing once, no warmup, GC noise dominates
t = Time.now; do_work; puts Time.now - t

# RIGHT: benchmark-ips handles warmup, GC, and statistical stability
```

## Profilers

### stackprof — the default CPU/wall/object profiler

`stackprof` is a sampling profiler — low overhead, safe in production-like loads. Three modes:
- `:cpu` — on-CPU time (find compute hotspots).
- `:wall` — wall-clock (find where you *wait*: IO, locks, sleeps).
- `:object` — samples allocations (find what allocates the most).

```ruby
require "stackprof"

StackProf.run(mode: :cpu, out: "tmp/stackprof-cpu.dump", interval: 1000) do
  expensive_call
end
```

```bash
stackprof tmp/stackprof-cpu.dump --text --limit 20   # top frames
stackprof tmp/stackprof-cpu.dump --method 'MyClass#slow'  # callers/callees
stackprof tmp/stackprof-cpu.dump --flamegraph > fg.html
```

Use `mode: :object` when GC time is high — it tells you *which line* allocates so you can cut it.

### vernier — modern sampling profiler (prefer for Ruby 3.2+)

`vernier` is the current best-in-class sampler: thread-aware, captures GC and idle/IO time, low overhead, and emits a profile for the Firefox Profiler UI. Prefer it over stackprof on Ruby 3.2+, especially for multi-threaded apps (Puma, Sidekiq).

```ruby
require "vernier"

Vernier.profile(out: "tmp/profile.json.gz") do
  do_work
end
```

```bash
vernier run -- ruby script.rb          # wrap a whole process
# Open tmp/profile.json.gz at https://profiler.firefox.com
```

Vernier shows time *between* threads and GC pauses that single-thread profilers miss. See `references/concurrency.md` for the threading model it visualizes.

### ruby-prof — deterministic, call-graph detail

`ruby-prof` instruments every call (high overhead, NOT for production) but gives exact call counts and a full call graph. Reach for it when you need precise *call counts* or a callgrind graph, not for sampling under load.

```ruby
require "ruby-prof"
result = RubyProf.profile { do_work }
RubyProf::FlatPrinter.new(result).print(STDOUT, min_percent: 2)
```

### rack-mini-profiler — web request profiling

For Rails/Rack, `rack-mini-profiler` adds an in-page speed badge with SQL, view, and allocation breakdowns per request. Pair with `flamegraph` and `stackprof` gems for `?pp=flamegraph`.

```ruby
# Gemfile (development)
gem "rack-mini-profiler"
gem "stackprof"   # enables ?pp=flamegraph
gem "memory_profiler"  # enables ?pp=profile-memory
```

```
GET /page?pp=flamegraph        # request flamegraph
GET /page?pp=profile-memory    # allocation report for the request
```

## Memory & allocation

In Ruby, **allocations are the dominant cost** — every object created is future GC work. Cutting allocations usually beats algorithmic tweaks.

### memory_profiler — what allocates and what retains

```ruby
require "memory_profiler"
report = MemoryProfiler.report { build_response }
report.pretty_print(to_file: "tmp/mem.txt")
```

Read two numbers: **allocated** (churn → GC pressure) and **retained** (lives past the block → leak/bloat). High allocated with low retained = GC thrash; high retained = a leak or oversized cache.

### derailed_benchmarks — Rails memory at boot and per-request

`derailed_benchmarks` finds gem memory bloat and per-request allocations.

```bash
bundle exec derailed bundle:mem      # memory used by requiring each gem
bundle exec derailed exec perf:mem   # per-request memory
bundle exec derailed exec perf:objects
```

### Frozen string literals cut allocations

Each unfrozen string literal allocates a *new* object every time it's evaluated; `# frozen_string_literal: true` dedups them into one shared frozen object, and you allocate a mutable buffer explicitly with `+""`. Mandatory at the top of every file you control — the allocation win is why. Mechanics (the magic comment, `+""`/`-"..."`, building with `<<`/`join`): see `references/language-idioms.md`.

### Avoid intermediate arrays

Chained `map`/`select`/`reject` each allocate a full intermediate array. Collapse them.

```ruby
# WRONG: 3 intermediate arrays of size ~N
users.select(&:active?).map(&:email).uniq

# RIGHT (single pass, one accumulator):
users.each_with_object(Set.new) { |u, s| s << u.email if u.active? }

# RIGHT (fuse two passes into one):
users.filter_map { |u| u.email if u.active? }.uniq
```

For large or lazy streams, use `lazy` so nothing is materialized until `.first`/`.take`/`.force`:

```ruby
# Reads/transforms only until 10 matches — no full intermediate arrays
File.foreach("huge.log").lazy
    .map { |line| parse(line) }
    .select { |e| e.error? }
    .first(10)
```

Tool choice within these pipelines (`filter_map`, `each_with_object` vs `reduce`, `lazy`): see `references/language-idioms.md` for the full Enumerable toolbox.

### Symbol vs string allocation

Symbols are interned (one object per name) and never churn the heap, so they're the right key/identifier type for hot hash lookups. Never `to_sym` untrusted/unbounded input — those symbols accumulate as memory growth. Symbol-vs-string semantics: see `references/language-idioms.md`.

### Build strings without churn

`out += ...` in a loop is O(n²) copying; build with `<<` into a `+""` buffer, or `map`/`join` once — see `references/language-idioms.md`. For very large output, stream instead of accumulating (see Streaming below).

## The garbage collector

MRI's GC is **generational** (young objects collected cheaply and often; long-lived ones promoted to old gen and scanned rarely) and **incremental** (the costly old-gen mark is sliced to bound pause time). The practical lever you control is *allocating fewer objects*; tuning is a second-order adjustment.

### GC.stat — read before you tune

```ruby
GC.stat(:major_gc_count)   # major (full) collections — expensive; want few
GC.stat(:minor_gc_count)   # minor — cheap & frequent is fine
GC.stat(:heap_live_slots)
GC.stat(:total_allocated_objects)  # churn proxy across run
GC.total_time                       # ns spent in GC (Ruby 3.x)
```

If `major_gc_count` climbs fast or `GC.total_time` is a large fraction of wall time, you have an allocation problem — go back to `memory_profiler`/stackprof `:object`, do not jump to env tuning.

### GC tuning env vars

Set via environment at process start (cannot change most after boot). Sensible starting points for a server that allocates heavily — raise *initial* slots so the heap doesn't repeatedly grow at boot:

```bash
RUBY_GC_HEAP_INIT_SLOTS=600000          # 3.2  (3.3+ split per size pool)
RUBY_GC_HEAP_GROWTH_FACTOR=1.1          # grow heap gently, fewer big jumps
RUBY_GC_HEAP_FREE_SLOTS_MAX_RATIO=0.20
RUBY_GC_MALLOC_LIMIT=64000000           # delay GC triggered by malloc growth
RUBY_GC_OLDMALLOC_LIMIT=128000000
```

Don't cargo-cult these — measure `GC.stat` before/after under realistic load. Wrong values waste RAM or trigger more majors. On Ruby 3.3+ the per-size-pool slot vars (`RUBY_GC_HEAP_%d_INIT_SLOTS`) exist; defaults are usually fine.

### GC.compact and auto-compaction

`GC.compact` defragments the heap, improving locality and CoW sharing across forked workers. Use `GC.auto_compact = true` or compact once after boot (after eager-load), before forking Puma/Sidekiq workers.

```ruby
# In an initializer / after eager load, before fork:
GC.compact
```

### Out-of-band GC

In forking servers, run a major GC *between* requests (off the hot path) so requests don't pay for it. Puma's `out_of_band` hook or `gctools`:

```ruby
# config/puma.rb
out_of_band { GC.start } if defined?(out_of_band)
```

Modern Ruby's incremental GC reduces the need; measure pause percentiles before adding this. Concurrency/fork details: see `references/concurrency.md`.

## Common hotspots

### N+1 queries

The single most common Rails performance bug. Eager-load associations; never trigger a query per row.

```ruby
# WRONG: 1 + N queries
Post.all.each { |p| puts p.author.name }

# RIGHT: 2 queries
Post.includes(:author).each { |p| puts p.author.name }
```

Detect with the `bullet` gem in dev. Full query-interface guidance (`includes`/`preload`/`eager_load`, `select`/`pluck`): see `references/rails.md`.

### Unbounded loads

Never load an unbounded result set into memory.

```ruby
# WRONG: loads the whole table at once
User.all.each { |u| process(u) }

# RIGHT: batches of 1000, constant memory
User.find_each { |u| process(u) }                 # iterate rows
User.in_batches(of: 5000) { |rel| rel.update_all(...) }  # batch operate
User.where(active: true).pluck(:id)               # only the column you need
```

`find_each`/`in_batches`/`pluck`/`select` semantics: see `references/rails.md`.

### Building huge strings / payloads

Stream, don't accumulate (see Streaming). For JSON, prefer `oj` or stream rather than building one giant string in memory.

### Regexp catastrophic backtracking

Nested quantifiers over the same input (`(a+)+`, `(\w+)*`) cause exponential time on a near-match — a CPU hotspot as well as a DoS vector. Fix by anchoring and using possessive/atomic groups (`/\A(?>\w+)\z/`), and set `Regexp.timeout` as a safety net. The defensive patterns and the `Regexp.timeout` API live in `references/security.md` (ReDoS).

### Date/Time parsing costs

`Date.parse`/`Time.parse` are slow (they sniff arbitrary formats) and ambiguous. When you know the format, use `strptime` — often 5–10x faster — or compare against precomputed values.

```ruby
# WRONG: format-sniffing on every row
Time.parse("2026-06-09T12:00:00Z")

# RIGHT: explicit format
Time.strptime("2026-06-09T12:00:00Z", "%Y-%m-%dT%H:%M:%S%Z")
Date.strptime("2026-06-09", "%Y-%m-%d")
```

## Caching strategies

### Memoization with `||=`

`@config ||= load_config` computes once per instance — a real win for repeated expensive calls. Two caveats live in the owning files: the nil/false `defined?` sentinel (`references/language-idioms.md`) and the thread-safety hazard — `||=` is not atomic, so for shared mutable caches use a `Mutex`/`Concurrent::Map` (`references/concurrency.md`). For a *parameterized* method, memoize into a hash keyed by args, not one ivar:

```ruby
def stats_for(id) = (@stats ||= {})[id] ||= compute(id)
```

### Store-based caching

For cross-request/process caching, use `Rails.cache` (low-level) with a sane expiry; pick the most specific store (Solid Cache / Redis / Memcached). Use `fetch` so misses populate atomically-enough.

```ruby
Rails.cache.fetch("user/#{user.id}/summary", expires_in: 1.hour) { build_summary(user) }
```

Russian-doll / fragment caching for views: see `references/rails.md`.

## Streaming & batching large data

Hold a window, not the whole dataset. Combine `find_each`/`in_batches` (DB) with `lazy` (transforms) and streaming output.

```ruby
# CSV streaming export — constant memory, no giant String
require "csv"
File.open("export.csv", "w") do |f|
  f.write CSV.generate_line(%w[id email])
  User.find_each { |u| f.write CSV.generate_line([u.id, u.email]) }
end
```

```ruby
# Rails: stream a response body instead of buffering it
self.response_body = Enumerator.new do |yielder|
  yielder << CSV.generate_line(%w[id email])
  User.find_each { |u| yielder << CSV.generate_line([u.id, u.email]) }
end
```

```ruby
# Lazy pipeline over an infinite/huge source
(1..Float::INFINITY).lazy.select(&:even?).map { |n| n**2 }.first(5)
```

## Choosing data structures

Lookup cost dominates in hot loops. `Array#include?` is **O(n)**; `Set#include?` and `Hash#key?` are **O(1)**.

```ruby
# WRONG: O(n) per check inside a loop → O(n*m) total
BANNED = ["a", "b", "c", "..."]   # array
ids.select { |id| BANNED.include?(id) }

# RIGHT: O(1) membership
require "set"
BANNED = Set["a", "b", "c"].freeze
ids.select { |id| BANNED.include?(id) }

# RIGHT: Hash when you also need an associated value
INDEX = records.index_by(&:id)    # Rails; one pass, then O(1) lookups
INDEX[some_id]
```

Use `Hash#group_by`/`tally`/`index_by` to pre-build O(1) indexes instead of repeated scans. Prefer `Comparable`/`<=>`-based sorting once over repeated `min`/`max` scans.

## YJIT

YJIT is Ruby's production JIT (mature since 3.2, faster/leaner each release). It speeds up CPU-bound Ruby method dispatch and arithmetic — typically 15–40% on real Rails apps — at a small memory cost. **Enable it; it rarely hurts.**

```bash
ruby --yjit script.rb
RUBYOPT="--yjit" rails server
# Or in code, early at boot:
```
```ruby
RubyVM::YJIT.enable   # Ruby 3.3+: turn on after boot (e.g. after fork-safe point)
```

```ruby
RubyVM::YJIT.runtime_stats   # inspect compiled ratio, etc.
```

When it helps most: CPU-bound, method-dispatch-heavy code (rendering, serialization). When it helps least: IO-bound waits (no Ruby running to compile) — there YJIT is neutral. Tune memory with `--yjit-exec-mem-size` if RSS matters. There is no good reason to leave YJIT off in production on 3.2+.

## When to drop to a lower level

After you've cut allocations, fixed algorithms, indexed lookups, and enabled YJIT, and a *measured* hotspot is still dominated by pure Ruby compute:
- Replace with a maintained C-extension gem (e.g. `oj` for JSON, `nokogiri` for XML, `blake3`/`bcrypt`) before writing your own.
- Write a C extension or use **Rust via `rb-sys`/Magnus** only for a tight, well-bounded, heavily-profiled kernel — it's a real maintenance/portability cost.
- Consider pushing work into the database (aggregate in SQL) or another process.
- Evaluate an alternate runtime (TruffleRuby/JRuby) for CPU-bound or true-parallel workloads — see `references/concurrency.md`.

Never reach here without a profile proving the Ruby code (not IO, not GC, not the DB) is the bottleneck.

## Quick checklist

- Profile first (vernier or stackprof; rack-mini-profiler for web). Fix the biggest item, then re-measure.
- Compare implementations with `benchmark-ips` + `compare!`, on realistically-sized data.
- Treat allocations as the cost: use `memory_profiler` (allocated vs retained); cut intermediate arrays with `filter_map`/`each_with_object`/`lazy`.
- Put `# frozen_string_literal: true` in every file; build with `<<` into a `+""` buffer or `join`, never `+=` in a loop.
- Use symbols for fixed keys; never `to_sym` untrusted/unbounded input.
- Eager-load to kill N+1; never load unbounded sets — `find_each`/`in_batches`/`pluck`/`select`.
- Use `Set`/`Hash` for membership in hot loops, not `Array#include?`; pre-build indexes with `index_by`/`tally`.
- Avoid `Time.parse`/`Date.parse` in hot paths — use `strptime`. Guard regexes against ReDoS; set `Regexp.timeout`.
- Memoize with `||=` (mind nil/false and thread-safety); use `Rails.cache.fetch` for cross-request caching.
- Read `GC.stat`/`GC.total_time` before touching `RUBY_GC_HEAP_*`; `GC.compact` after eager-load before fork.
- Enable YJIT in production on Ruby 3.2+.
- Drop to a C/Rust extension only for a profiled, isolated kernel — prefer an existing native gem.
