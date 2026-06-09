# Metaprogramming & DSLs

Metaprogramming is Ruby code that defines or alters code at runtime. It is powerful and abused often. **Default to plain Ruby.** Reach for these tools only when they delete real, repeated duplication that no normal abstraction (method, module, value object) can. Every dynamic method must be **documented and tested** — it is invisible to `grep`, LSP, and the next reader.

See `references/oo-design.md` for when a value/service object beats a DSL, and `references/language-idioms.md` for blocks/procs/Enumerable basics this file assumes.

## The object model

Three facts drive everything below:

1. **Classes are objects** (instances of `Class`). `class Foo; end` is sugar for assigning a `Class` instance to constant `Foo`.
2. **Every object has a singleton class** (a.k.a. eigenclass / metaclass) holding methods unique to that one object. "Class methods" are just instance methods on the class's singleton class.
3. **Method lookup walks `ancestors`** left to right: singleton class → prepended modules → the class → included modules → superclass (recursively) → `BasicObject`.

```ruby
class A; end
module M; end
class B < A; include M; end

B.ancestors          # => [B, M, A, Object, Kernel, BasicObject]
B.singleton_class.ancestors.first(3)
# => [#<Class:B>, #<Class:A>, #<Class:Object>]  (class-method lookup chain)

obj = Object.new
def obj.greet = "hi"           # defines on obj's singleton class
obj.singleton_class.instance_methods(false)  # => [:greet]
```

### include / prepend / extend + super

```ruby
module Logged
  def save
    puts "before"
    r = super          # calls the next save in ancestors
    puts "after"
    r
  end
end

class Doc
  prepend Logged       # Logged sits BEFORE Doc -> its #save wins, super hits Doc#save
  def save = :saved
end
Doc.new.save           # before / after / => :saved
```

- `include M` — inserts `M` **after** the class in ancestors (instance methods, overridable by the class).
- `prepend M` — inserts `M` **before** the class; ideal for wrapping/decorating an existing method via `super` (the modern replacement for `alias_method` chains).
- `extend M` — adds `M`'s methods to a single object's singleton class. `obj.extend(M)`; at class level `extend M` makes M's methods class methods.

```ruby
# WRONG (old pattern): alias-method chaining is fragile and order-dependent
alias_method :save_without_log, :save
def save; log; save_without_log; end

# RIGHT: prepend a module and call super
prepend Logged
```

## define_method — dynamic method generation

Use when you'd otherwise copy-paste near-identical methods. The block is a closure (captures surrounding scope), unlike `def`.

```ruby
class Settings
  %i[host port timeout].each do |name|
    define_method(name) { @config[name] }
    define_method("#{name}=") { |v| @config[name] = v }
  end
end
```

Prefer `define_method` over `class_eval("def ...")` with string interpolation: it is faster to define, safer (no string injection), and shows in backtraces. Only use string `class_eval` if you need the absolute fastest *call-time* method and have profiled it (see `references/performance.md`).

```ruby
# Acceptable string form when call-time speed is proven-critical & names are trusted constants:
class_eval <<~RUBY, __FILE__, __LINE__ + 1
  def #{name}; @#{name}; end
RUBY
```

Always pass `__FILE__, __LINE__ + 1` to string evals so backtraces point at the real source.

## method_missing — always paired with respond_to_missing?

`method_missing` is the fallback when lookup fails. **Never define it without `respond_to_missing?`** — otherwise `respond_to?`, `method()`, `Symbol#to_proc`, and duck-typing checks lie about the object.

```ruby
class DynamicConfig
  def initialize(data = {}) = @data = data

  def method_missing(name, *args)
    key = name.to_s.chomp("=")
    if name.to_s.end_with?("=")
      @data[key] = args.first
    elsif @data.key?(key)
      @data[key]
    else
      super            # let Ruby raise a proper NoMethodError
    end
  end

  def respond_to_missing?(name, include_private = false)
    @data.key?(name.to_s.chomp("=")) || super
  end
end
```

Rules: always call `super` for the unhandled case (gives a correct `NoMethodError` with `did_you_mean`); keep the matching logic identical in both methods.

**Costs:** every missing call walks the *entire* ancestor chain before reaching `method_missing`, so it is far slower than a real method, and it defeats tooling/autocomplete. Prefer defining real methods up front:

```ruby
# BETTER than method_missing when the key set is known: define them once
class Config
  def self.attribute(name)
    define_method(name) { @data[name] }
  end
end
```

A common upgrade is to **define the method on first use** inside `method_missing`, so later calls hit a real method (define-on-miss):

```ruby
def method_missing(name, *args, &blk)
  if dynamic?(name)
    self.class.define_method(name) { @data[name] }   # define once
    send(name)
  else
    super
  end
end
```

## send / public_send

`send` invokes a method by name, **including private methods**. `public_send` respects visibility — use it unless you specifically need private access.

```ruby
public_send(action)         # respects private/protected — safe default
send(:internal_helper)      # only when you intentionally bypass privacy
```

**Security:** never pass unsanitized user input to `send`/`public_send` — it lets a caller invoke arbitrary methods (`destroy`, `system`, ...). Allowlist first.

```ruby
# WRONG — arbitrary method invocation
record.public_send(params[:field])

# RIGHT — allowlist
ALLOWED = %w[name email created_at].freeze
record.public_send(field) if ALLOWED.include?(field)
```

See `references/security.md`.

## Instance variables & singleton methods reflectively

```ruby
obj.instance_variable_get(:@name)          # read; returns nil if unset (no warning)
obj.instance_variable_set(:@name, "Ada")
obj.instance_variables                       # => [:@name]

obj.define_singleton_method(:shout) { @name.upcase }  # method on this object only
```

Use sparingly — reaching into another object's ivars breaks encapsulation. It is legitimate inside serializers, test setup, and the object's own metaprogramming.

## Module / Class hooks

These callbacks fire when modules/classes are used, enabling DSLs that inject both instance and class behavior.

```ruby
module Trackable
  def self.included(base)        # fires on `include Trackable`
    base.extend(ClassMethods)    # add class-level methods
    base.class_eval { @records = [] }
  end

  module ClassMethods
    def all = @records
    def track(r) = (@records << r)
  end

  def save = self.class.track(self)
end
```

Hooks: `included(base)`, `extended(obj)`, `prepended(base)`, `inherited(subclass)` (subclass registration), and `method_added` / `method_removed`. In Rails, prefer `ActiveSupport::Concern` which formalizes the include+extend+`included do` pattern — see `references/rails.md`.

### Anonymous classes/modules

```ruby
klass = Class.new(StandardError)            # anonymous, assign to a const to name it
NotFound = Class.new(StandardError)         # now named "NotFound"

mod = Module.new do
  define_method(:tag) { "x" }
end
Object.include(mod)                          # generate behavior at runtime
```

`Class.new(Super) { ... }` and `Module.new { ... }` are the runtime-construction primitives behind many DSLs and factories.

## class_eval / instance_eval / instance_exec

- `Klass.class_eval { def foo; end }` — runs in **class context**; `def`/`define_method` add **instance** methods. Reopens a class given only a reference.
- `obj.instance_eval { @ivar }` — runs with `self = obj`; `def` here defines a **singleton** method. Reads/writes the object's ivars.
- `instance_exec(*args) { |x| ... }` — like `instance_eval` but passes arguments into the block. Essential for DSL blocks that need outside data.

```ruby
config.instance_exec(env) { |e| @url = e.fetch("URL") }
```

Note the asymmetry: inside `class_eval`, `def` makes instance methods but `define_method` is needed to capture closures; inside `instance_eval`, `def` makes singleton methods.

### binding

`binding` captures the local scope (variables, `self`) as a `Binding` object — used by templating (ERB) and debuggers (`binding.irb`, the `debug` gem's `binding.break`; see `references/tooling.md`).

```ruby
require "erb"
name = "Ada"
ERB.new("Hi <%= name %>").result(binding)
```

## Internal DSLs

Two clean styles. Prefer **explicit `define_method`/declared macros** over `method_missing` DSLs — they are greppable, autocompletable, and fail loudly on typos.

### Class-macro DSL (declarative, preferred)

```ruby
class Mapper
  def self.field(name, from:)
    fields[name] = from
    define_method(name) { @data[from] }
  end
  def self.fields = @fields ||= {}

  def initialize(data) = @data = data
end

class UserMapper < Mapper
  field :email, from: "email_address"   # reads as configuration
end
```

### Block/builder DSL with instance_eval

Good for nested config. Beware: inside `instance_eval`, the block can't see the caller's methods/ivars (self is swapped) — pass needed data via `instance_exec`, and document that gotcha.

```ruby
class RouteBuilder
  def self.draw(&blk)
    b = new
    b.instance_eval(&blk)
    b.routes
  end
  def initialize = @routes = []
  def get(path, to:) = @routes << [:get, path, to]
  attr_reader :routes
end

RouteBuilder.draw do
  get "/health", to: "system#health"
end
```

### method_missing DSL (use only when keys are open-ended)

Justified when the vocabulary is genuinely unbounded (e.g. a builder for arbitrary HTML tags). Otherwise prefer macros above.

## Introspection

```ruby
String.instance_methods(false)        # methods defined directly on String
obj.methods - Object.instance_methods # what this object adds
obj.method(:foo).source_location      # ["file.rb", 12] — find dynamic defs
obj.respond_to?(:foo)
Foo.const_get(:Bar)                   # resolve "Foo::Bar" dynamically
Object.const_get("A::B::C")           # const_get follows :: in a string
Foo.instance_method(:foo).parameters  # [[:req, :x], [:key, :y]]
```

`source_location` is the best tool for *finding* where a dynamic method was defined — make sure your generators produce a usable one.

### ObjectSpace caveats

`ObjectSpace.each_object(SomeClass)` enumerates live instances but is **slow, GC-dependent, and disabled/limited on JRuby & TruffleRuby**. Use only for debugging/diagnostics, never in production logic. `ObjectSpace.count_objects` and `memsize_of` are useful in profiling (see `references/performance.md`).

## TracePoint

`TracePoint` hooks runtime events (`:call`, `:line`, `:raise`, `:class`). For diagnostics/instrumentation only — it is expensive and global.

```ruby
tp = TracePoint.new(:call) { |t| puts "#{t.defined_class}##{t.method_id}" }
tp.enable { run_something }   # active only inside the block
```

Never ship TracePoint in a hot path. It powers debuggers and coverage tools, not application logic.

## Refinements vs monkey-patching

**Monkey-patching** (reopening a class globally) is a last resort: it is action-at-a-distance, can break other gems, and is invisible. If you must, do it in a clearly named file, only add (never silently override) behavior, and consider `prepend` so the original is reachable via `super`.

**Refinements** scope a patch lexically — active only in files that `using` them. Safer than global patches but have sharp edges (no dynamic dispatch into refined methods from `send` in some versions, ignored by metaprogramming, lexical-only).

```ruby
module StringExt
  refine String do
    def shout = upcase + "!"
  end
end

# in another file:
using StringExt          # active only for the rest of THIS file (lexical scope)
"hi".shout               # => "HI!"
```

Guidance:
- **First choice:** add a method to *your own* class/module, or a helper/service object — no patching at all.
- **Acceptable:** a refinement for a small, localized extension of a core class within your own code.
- **Avoid:** global monkey-patches of stdlib/core or third-party gem internals. If unavoidable, isolate and test heavily.

## Quick checklist

- Prefer plain Ruby; use metaprogramming only to remove real, repeated duplication.
- Document and write tests for every dynamically defined method; ensure `source_location` works.
- `method_missing` ⇒ always define `respond_to_missing?` too, and `super` for the unhandled case.
- Prefer declarative `define_method`/class-macros over `method_missing` DSLs (greppable, autocompletable).
- Use `define_method` over string `class_eval`; if you must use string eval, pass `__FILE__, __LINE__ + 1`.
- Use `prepend` + `super` instead of `alias_method` chains to wrap methods.
- Use `public_send` by default; `send` only to intentionally bypass privacy.
- Never pass user input to `send`/`public_send`/`const_get` without an allowlist.
- Use `prepend`/refinements over global monkey-patching; never override core/gem internals globally.
- `ObjectSpace.each_object` and `TracePoint` are diagnostics-only — keep them out of production paths.
- In Rails, reach for `ActiveSupport::Concern` instead of hand-rolled `included`/`extend` plumbing.
