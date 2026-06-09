# Concurrency & parallelism

How to pick and use a concurrency model in modern Ruby (MRI/CRuby 3.2–3.4). The single most important fact: **MRI has a Global VM Lock (GVL), so threads give you concurrency for IO-bound work but NOT parallelism for CPU-bound work.** Choose the model from the workload, not from habit.

## The GVL/GIL — what it does and does not do

The GVL (historically "GIL") ensures only **one thread executes Ruby bytecode at a time** in a single MRI process.

- It **does** prevent true parallel execution of pure-Ruby CPU work. Two threads spinning on math run no faster than one.
- It is **released** during blocking IO (sockets, file reads, `sleep`, many DB driver calls) and during some C-extension sections. So while one thread waits on the network, another runs Ruby. This is why threads help IO-bound workloads.
- It does **NOT** make your code thread-safe. The GVL can switch threads between bytecode instructions, so `count += 1` (read, add, write) can interleave and lose updates. You still need locks. See "Thread-safety hazards" below.

```ruby
# CPU-bound: threads do NOT help on MRI (GVL serializes the work)
threads = 4.times.map { Thread.new { fib(35) } }  # ~same wall time as serial
threads.each(&:join)

# IO-bound: threads DO help (GVL released during the HTTP wait)
urls.map { |u| Thread.new { Net::HTTP.get(URI(u)) } }.each(&:join)
```

JRuby and TruffleRuby have **no GVL** — threads run truly parallel there, so CPU-bound threading works on those runtimes.

## Thread basics

```ruby
t = Thread.new(arg) do |x|   # pass args explicitly; do NOT close over a loop var
  do_work(x)
end
result = t.value             # join + return the block's value (re-raises if it failed)
t.join                       # wait without caring about return value
t.join(5)                    # returns nil on timeout, else the thread
```

DO pass loop variables as block args; DON'T capture them by closure:

```ruby
# WRONG: all threads may see the final value of `i`
(0..9).each { |i| Thread.new { puts i } }

# RIGHT: bind per-thread via block argument
(0..9).each { |i| Thread.new(i) { |n| puts n } }
```

**Thread-local / fiber-local storage.** `Thread#[]` is actually *fiber*-local (scoped to the current fiber). Use `Thread#thread_variable_get/set` for true per-thread state.

```ruby
Thread.current[:tag] = "fiber-local"          # fiber-scoped (surprising name)
Thread.current.thread_variable_set(:id, 7)    # genuinely thread-scoped
```

### Exceptions in threads

An unhandled exception in a thread is stored and **re-raised when you call `join`/`value`**. If you never join, the exception is silently swallowed.

```ruby
t = Thread.new { raise "boom" }
sleep 0.1            # main thread keeps running; nothing printed yet
t.join               # NOW it raises "boom"
```

DON'T flip `Thread.abort_on_exception = true` globally in libraries (it crashes the whole process on any thread error). For dev visibility prefer `Thread.report_on_exception = true` (default since 2.5) which logs but doesn't abort. Better: always `join` or wrap work in `begin/rescue` and push errors to a `Queue`.

## Synchronization primitives

### Mutex

```ruby
mutex = Mutex.new
mutex.synchronize { @balance += amount }   # critical section
```

DON'T re-lock the same `Mutex` from the same thread (e.g. recursive call) — it raises `ThreadError` (deadlock). Use `Monitor` for reentrancy.

### Monitor (reentrant mutex + condition vars)

```ruby
require "monitor"
class Counter
  include MonitorMixin               # adds #synchronize to instances
  def initialize = (super; @n = 0)
  def incr = synchronize { @n += 1 } # reentrant: safe to call other synchronized methods
end
```

### ConditionVariable — wait/signal

Use when a thread must wait for a condition another thread sets. Always re-check the predicate in a loop (guard against spurious wakeups).

```ruby
mutex, cond = Mutex.new, ConditionVariable.new
ready = false

# consumer
mutex.synchronize { cond.wait(mutex) until ready; consume }
# producer
mutex.synchronize { ready = true; cond.signal }   # or broadcast for all waiters
```

### Queue / SizedQueue — the preferred producer-consumer tool

`Thread::Queue` is thread-safe and blocking out of the box. Prefer it over hand-rolled Mutex+ConditionVariable.

```ruby
q = Thread::Queue.new            # unbounded
sq = Thread::SizedQueue.new(100) # bounded -> applies backpressure on push

# producers
producers = files.map { |f| Thread.new { sq.push(parse(f)) } }

# consumers
workers = 4.times.map do
  Thread.new do
    while (item = sq.pop)        # pop blocks until an item is available
      handle(item)
    end
  end
end

producers.each(&:join)
workers.size.times { sq.push(nil) }  # poison pills to stop consumers
workers.each(&:join)
# Alt: sq.close then `while (i = sq.pop); ...` exits when closed+drained
```

`SizedQueue` is the idiomatic way to bound memory and rate: `push` blocks when full.

## concurrent-ruby (`Concurrent::*`)

Battle-tested toolkit. Reach for it instead of building pools/atomics yourself.

```ruby
require "concurrent-ruby"

# Bounded thread pool (don't spawn unbounded threads)
pool = Concurrent::FixedThreadPool.new(8)
pool.post { do_io }
pool.shutdown; pool.wait_for_termination

# Futures (run now, collect later)
futures = urls.map { |u| Concurrent::Future.execute { Net::HTTP.get(URI(u)) } }
results = futures.map(&:value)         # blocks; check #rejected? / #reason for errors

# Thread-safe map (use instead of a plain Hash shared across threads)
cache = Concurrent::Map.new
cache.compute_if_absent(key) { expensive(key) }   # atomic memoization

# Atomic counter (no Mutex needed)
counter = Concurrent::AtomicFixnum.new(0)
counter.increment
```

Other useful types: `Concurrent::Array`/`Concurrent::Hash` (thread-safe wrappers), `Concurrent::Promises` (composable futures), `Concurrent::TimerTask`, `Concurrent::ThreadLocalVar`.

DON'T use raw `Concurrent::Future`/`Promise` without checking for rejection — a failed future returns `nil` from `value` and hides the error in `#reason`.

## Thread-safety hazards & patterns

### Shared mutable state

Any object mutated by multiple threads needs a lock or a thread-safe type. Plain `Hash`, `Array`, and `+=` are NOT atomic.

```ruby
# WRONG: lost updates under contention
@total += n
@list << item
@hash[k] = v

# RIGHT: guard with a mutex, or use Concurrent::* types
@mutex.synchronize { @total += n }
```

### Check-then-act races

`if !exists then create` is two operations; another thread can act in between.

```ruby
# WRONG (TOCTOU)
@conn = connect unless @conn

# RIGHT: atomic compute-if-absent, or lock the whole check+act
@mutex.synchronize { @conn ||= connect }
```

### Memoization races

`@x ||= compute` is fine for **idempotent, side-effect-free** values where a rare double-compute is harmless. It is NOT safe when `compute` has side effects or must run exactly once.

```ruby
# Risky if compute is expensive/side-effectful: two threads may both run it
def config = @config ||= load_config

# Safe: compute exactly once
def config
  @mutex.synchronize { @config ||= load_config }
end
```

Pattern: **make objects immutable and share those**. Build state on one thread, `freeze` it, hand the frozen object to others. Frozen + no shared mutation = no locks needed.

## Fibers & the Fiber scheduler

Fibers are cooperative, lightweight units of execution (no OS thread per fiber). You can have hundreds of thousands. They yield control explicitly.

```ruby
f = Fiber.new { puts "a"; Fiber.yield; puts "b" }
f.resume   # => "a"
f.resume   # => "b"
```

Since Ruby 3.0 a **Fiber scheduler** can make blocking IO automatically yield, so thousands of fibers multiplex over a few threads with normal-looking blocking code. You rarely implement the scheduler yourself — use the `async` gem.

```ruby
Fiber.set_scheduler(MyScheduler.new)   # what `Async{}` does for you
```

## The `async` gem — high-concurrency IO

Idiomatic high-level fiber concurrency. Code reads sequentially but runs concurrently; IO automatically suspends the fiber.

```ruby
require "async"
require "async/http/internet"

Async do |task|
  internet = Async::HTTP::Internet.new
  results = urls.map do |u|
    task.async { internet.get(u).read }   # each runs concurrently
  end.map(&:wait)
ensure
  internet&.close
end
```

Bound concurrency with a **Semaphore**; coordinate completion with a **Barrier**:

```ruby
require "async/semaphore"
require "async/barrier"

Async do
  barrier   = Async::Barrier.new
  semaphore = Async::Semaphore.new(10, parent: barrier)  # max 10 in flight

  urls.each { |u| semaphore.async { fetch(u) } }
  barrier.wait     # wait for all spawned tasks
end
```

DON'T mix `async`-style fiber concurrency with blocking C-extensions that don't release the GVL or cooperate with the scheduler — they block the whole reactor. Use `async`-aware libraries (e.g. `async-http`, `async-postgres`).

## Ractors — true parallelism on MRI (experimental)

Ractors run Ruby code **in parallel** (each has its own GVL) by forbidding shared mutable state. As of 3.2–3.4 they are still **experimental** (emit a warning) and many gems aren't Ractor-safe.

- Only **shareable** objects cross Ractor boundaries: immutable/frozen objects, `Integer`, `Symbol`, `true/false/nil`, deeply-frozen structures, classes/modules. Check with `Ractor.shareable?(obj)`.
- Communicate by **message passing**, not shared memory: `send`/`receive` (copy, mailbox) and `yield`/`take` (push/pull).

```ruby
r = Ractor.new do
  msg = Ractor.receive          # block until a message arrives
  msg * 2
end
r.send(21)
r.take                          # => 42  (the block's value)

# Parallel map across CPUs
ractors = inputs.map { |x| Ractor.new(x) { |v| heavy_cpu(v) } }
results = ractors.map(&:take)
```

Limits to know: non-shareable globals/constants raise `IsolationError`; many stdlib/gems aren't Ractor-safe; debugging is harder; the warning is emitted on first use. Treat Ractors as promising for isolated CPU-bound fan-out, not as a drop-in thread replacement yet.

## Processes & fork — real parallelism, the safe default for CPU work on MRI

Separate processes each have their own GVL, so they run in parallel. The cost is no shared memory (communicate via pipes/IPC) and OS process overhead.

```ruby
pid = Process.fork do
  # child: independent memory (copy-on-write of parent's pages)
  result = heavy_cpu
  # return value is NOT visible to parent — must use IPC
end
Process.wait(pid)               # reap the child; avoid zombies
```

Pass results back over an `IO.pipe` (or use a higher-level tool):

```ruby
reader, writer = IO.pipe
pid = fork { reader.close; writer.write(Marshal.dump(compute)); writer.close }
writer.close
data = Marshal.load(reader.read); reader.close
Process.wait(pid)
```

`fork` is **not available on Windows** and is fragile with threads (only the forking thread survives in the child) and with open connections/file handles — reconnect DBs/clients in the child.

### `parallel` gem — fork made easy

```ruby
require "parallel"
# CPU-bound: spread across cores with processes
Parallel.map(items, in_processes: 8) { |i| heavy_cpu(i) }
# IO-bound: lighter-weight threads
Parallel.map(items, in_threads: 16) { |i| fetch(i) }
```

`in_processes` serializes args/results via Marshal across the fork boundary — objects must be Marshalable, and side effects in children don't propagate back.

## Choosing a model

| Workload | Use |
|---|---|
| IO-bound, moderate concurrency | Threads + `SizedQueue`, or `Concurrent::FixedThreadPool` |
| IO-bound, very high concurrency (10k+ sockets) | Fibers via the `async` gem |
| CPU-bound on MRI | Processes (`fork` / `parallel` gem) or Ractors (if isolatable) |
| CPU-bound, want shared memory + parallelism | JRuby or TruffleRuby (no GVL) |

Rules of thumb:
- IO-bound -> **threads / async / fibers**.
- CPU-bound -> **processes / Ractors / JRuby / TruffleRuby**.
- Always **bound** concurrency (fixed pool, sized queue, semaphore). Unbounded `Thread.new` per item exhausts memory and OS threads.

Rails background jobs (ActiveJob/Sidekiq) are a separate, higher-level concern — see references/rails.md. Profiling concurrency for performance — see references/performance.md.

## Timeouts — `Timeout` caveats

`Timeout.timeout` raises an exception in the target thread at an **arbitrary point**, which can interrupt the middle of a critical section, leave locks held, or corrupt state. Treat it as a last resort.

```ruby
# RISKY: can fire mid-operation, leaving inconsistent state / undefined behavior
Timeout.timeout(5) { do_complex_thing }

# PREFER: native/library timeouts that abort cleanly at safe points
Net::HTTP.start(host, open_timeout: 5, read_timeout: 5) { ... }
db.connect(connect_timeout: 5)
socket.read_nonblock(...)   # with IO.select for the deadline
```

If you must use `Timeout`, keep the block tiny, avoid holding mutexes inside it, and never wrap operations that mutate shared state without cleanup.

## Quick checklist

- MRI GVL: threads help **IO-bound**, never CPU-bound. CPU-bound -> processes/Ractors/JRuby/TruffleRuby.
- The GVL does **not** make code thread-safe; `+=`, `<<`, `Hash[]=` are not atomic.
- Always `join`/`value` threads (or push errors to a `Queue`) — unjoined exceptions vanish.
- Pass loop vars as block args to `Thread.new(x) { |x| }`; don't capture by closure.
- Prefer `Thread::Queue`/`SizedQueue` for producer-consumer; use `SizedQueue` for backpressure.
- Use `Concurrent::*` (FixedThreadPool, Future, Map, AtomicFixnum) over hand-rolled primitives.
- Guard check-then-act and side-effecting memoization with a `Mutex`/`Monitor`; `||=` only for idempotent values.
- Prefer immutable, `frozen` objects shared across threads to avoid locks entirely.
- Bound concurrency: fixed pools, sized queues, `Async::Semaphore`. Never unbounded `Thread.new`.
- High-concurrency IO -> `async` gem (`Async{}`, semaphores, barriers).
- Ractors are experimental: only shareable/frozen objects cross boundaries; communicate by message passing.
- `fork`: no Windows, fragile with threads/connections; reconnect clients in the child; reap with `Process.wait`.
- Avoid `Timeout.timeout` for stateful work — prefer library/socket-level timeouts.
