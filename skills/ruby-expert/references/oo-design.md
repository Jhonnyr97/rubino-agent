# Object-oriented design

Idiomatic Ruby OO for Ruby 3.2–3.4 / Rails 7.1–8.x. Ruby is dynamically typed with
duck typing, open classes, and mixins — so the "OO design" advice from statically
typed languages mostly applies, but the *mechanics* differ. Lean on objects that
respond to messages, not on type hierarchies.

Cross-references (don't re-explain these here):
- Metaprogramming mechanics (define_method, method_missing, eigenclass) → `references/metaprogramming.md`
- Exception hierarchy & rescue rules → `references/errors-and-types.md`
- Rails layering (concerns, app/services, callbacks) → `references/rails.md`

## SOLID, the Ruby way

SOLID is a set of pressures, not laws. Apply with duck typing in mind.

**S — Single Responsibility.** A class should have one reason to change. The Ruby
smell test: can you describe the class in one sentence without "and"? If `User`
both persists data *and* renders emails *and* charges cards, split it.

**O — Open/Closed.** Extend behavior without editing existing code. In Ruby this is
usually composition + injection, not abstract base classes. New behavior = a new
object passed in, not a new `elsif`.

```ruby
# WRONG — every new format edits this method (closed to extension)
def export(data, format)
  case format
  when :csv  then CSVWriter.new.write(data)
  when :json then JSONWriter.new.write(data)
  end
end

# RIGHT — inject a writer that responds to #write; add formats without editing
def export(data, writer:)
  writer.write(data)
end
```

**L — Liskov Substitution.** Any object passed where another is expected must honor
the same *implicit contract* (same messages, same return shape, no surprise
exceptions). In Ruby the "type" is the set of messages it answers — the role, not
the class. A `NullLogger` must accept `#info`/`#error` just like `Logger`.

**I — Interface Segregation.** Don't force collaborators to depend on messages they
don't use. Keep modules/roles small; a giant `include Everything` couples callers
to methods they never call.

**D — Dependency Inversion.** Depend on roles (duck types), not concrete classes.
Pass collaborators in; don't `SomeClass.new` deep inside a method.

```ruby
# WRONG — hard-wired dependency; untestable without hitting Stripe
class Checkout
  def call(order)
    Stripe::Charge.create(amount: order.total)
  end
end

# RIGHT — depend on a "gateway" role; default to the real one
class Checkout
  def initialize(gateway: StripeGateway.new)
    @gateway = gateway
  end

  def call(order)
    @gateway.charge(order.total)
  end
end
```

## Sandi Metz's rules — heuristics, not dogma

Treat these as tripwires that prompt a second look, not hard failures:

- Classes ≤ **100 lines**.
- Methods ≤ **5 lines** (a body of 5 lines, excluding `def`/`end`).
- Method signatures ≤ **4 parameters** (kwargs count individually).
- Controllers/views: **one instance variable** per view, send one message to it.

You may break a rule only if you can convince a teammate it's justified. A 6-line
method that's clearer than two 3-line methods is fine. The point is the *friction*:
when you blow past 100 lines, ask whether a second object is hiding inside.

Also useful — the "squint test" and: extract a class the moment a method needs
data from another object more than from `self` (feature envy).

## Composition over inheritance

Prefer **has-a** over **is-a**. Inheritance couples subclass to superclass internals
and forces a single rigid axis of variation. Composition lets you swap parts.

```ruby
# WRONG — inheritance for code reuse; deep, brittle hierarchy
class Report; def header; ...; end; end
class PdfReport < Report; end       # now coupled to Report's privates
class CsvReport < Report; end

# RIGHT — compose a formatter (a role), inject it
class Report
  def initialize(formatter:)
    @formatter = formatter
  end

  def render(rows) = @formatter.format(rows)
end

Report.new(formatter: PdfFormatter.new)
Report.new(formatter: CsvFormatter.new)
```

Use inheritance only for genuine *is-a* specialization where the subclass is
substitutable and the hierarchy is shallow (1–2 levels). Template Method (abstract
superclass calling subclass hooks) is the one inheritance pattern that stays clean.

## Mixins / modules — the Ruby way to share behavior, and the traps

Modules let you share behavior across unrelated classes. Three insertion points:

```ruby
module Greet
  def hello = "hi from #{name}"
end

class A; include Greet; end   # instance methods
class B; extend  Greet; end   # class/singleton methods
class C; prepend Greet; end   # inserted BEFORE C in ancestors (wraps methods)
```

Use a module when it represents a **role** several classes can play (`Comparable`,
`Enumerable`, `Trackable`). Define the small "core" method in the class and let the
module build on it — exactly how `Comparable` needs only `<=>`:

```ruby
class Version
  include Comparable
  attr_reader :n
  def initialize(n) = @n = n
  def <=>(other) = n <=> other.n     # Comparable gives ==, <, >, between?, clamp
end
```

**Pitfalls:**
- **Hidden coupling on host state.** A module method calling `name`/`@total`
  silently requires every host to provide it. Document the required interface.
- **Namespace/method collisions.** `include`d methods land directly in the
  ancestor chain; two modules defining `process` clash silently (last wins).
- **"Concern soup."** Don't use modules as a junk drawer to shrink a class — that
  hides the size, it doesn't fix the design. If a module only makes sense with one
  host and shares its ivars, it's not a role; it's that class wanting to be split
  into a *collaborator* (see composition). Rails-specific concern guidance lives in
  `references/rails.md`.
- Modules can't be instantiated and carry no per-instance state of their own.

Rule of thumb: **composition for state + behavior, mixins for stateless behavior /
shared roles.**

## Duck typing, "tell don't ask", Law of Demeter

**Duck typing:** depend on what an object *does*, not its class.

```ruby
# WRONG — type-checking defeats polymorphism
def total(items)
  items.sum { |i| i.is_a?(Discounted) ? i.discount_price : i.price }
end

# RIGHT — every item answers #price; let it decide
def total(items) = items.sum(&:price)
```

Avoid `is_a?`/`kind_of?`/`respond_to?` branching for control flow. If you must check
capability, `respond_to?` is the least-bad option, but a polymorphic method or a
Null Object is usually better.

**Tell, don't ask:** send a command instead of pulling state out to decide.

```ruby
# WRONG — ask then act (logic leaks to the caller)
if account.balance >= amount
  account.balance -= amount
end

# RIGHT — tell the object; it enforces its own invariants
account.withdraw(amount)
```

**Law of Demeter** ("only talk to your immediate neighbors"): avoid chains that
reach through objects. `a.b.c.d` couples you to the whole graph.

```ruby
# WRONG — train wreck; knows about company AND address internals
user.company.address.zip_code

# RIGHT — delegate, exposing intent not structure
class User
  def company_zip = company.zip_code
end
# or in Rails:
delegate :zip_code, to: :company, prefix: true   # user.company_zip_code
```

Chains on a *collection pipeline* (`items.select{}.map{}.sum`) are fine — that's one
object (Enumerable), not a Demeter violation.

## Value objects (Data.define)

Immutable, compared by value, no identity. Use `Data.define` (Ruby 3.2+) for these —
it gives `==`, `hash`, `eql?`, keyword + positional init, `with`, and `deconstruct`.

```ruby
Money = Data.define(:cents, :currency) do
  def +(other)
    raise ArgumentError, "currency mismatch" unless currency == other.currency
    with(cents: cents + other.cents)        # returns a NEW Money
  end

  def to_s = format("%.2f %s", cents / 100.0, currency)
end

a = Money.new(cents: 500, currency: "USD")
b = Money[300, "USD"]                 # positional via []
a + b                                 # => #<data Money cents=800 ...>
a == Money.new(cents: 500, currency: "USD")  # => true (value equality)
```

`Data` instances are frozen and have **no setters** — that's the point. Use `Struct`
only when you genuinely need mutability or array-style access; otherwise prefer
`Data`. (Struct vs Data detail → `references/language-idioms.md`.)

## Service objects — one public `#call`

A service object models a *verb* / use case. Convention: one public method, named
`#call`, collaborators injected in `#initialize`, returns a Result (below).

```ruby
class RegisterUser
  def self.call(...) = new(...).call          # convenience entry point

  def initialize(repo: UserRepository.new, mailer: WelcomeMailer)
    @repo = repo
    @mailer = mailer
  end

  def call(email:, password:)
    return Result.failure(:invalid_email) unless email.include?("@")

    user = @repo.create(email:, password:)
    @mailer.deliver(user)
    Result.success(user)
  end

  private attr_reader :repo, :mailer    # private + everything else below
end
```

Do: keep `#call` thin and orchestrative; push real logic into domain objects.
Don't: stuff seven public methods in and call it a "service" — that's just a class
with a vague name. (Placement under `app/services` → `references/rails.md`.)

## Form / query / policy objects, decorators/presenters

**Form object** — coordinates validation/persistence across multiple models or
non-AR input. Wraps params, exposes `valid?` + `save`, keeps controllers thin.

```ruby
class SignupForm
  include ActiveModel::Model                 # gives validations + #valid?
  attr_accessor :email, :company_name
  validates :email, presence: true

  def save
    return false unless valid?
    ActiveRecord::Base.transaction { create_company! && create_user! }
  end
end
```

**Query object** — encapsulates a non-trivial DB query (reuse, testability) instead
of fat scopes or controller-built relations.

```ruby
class ActivePremiumUsers
  def initialize(relation = User.all) = @relation = relation
  def call = @relation.where(active: true).where(plan: :premium).order(:created_at)
end
```

**Policy object** — answers a yes/no authorization/business question.

```ruby
class PublishPolicy
  def initialize(user, post) = (@user, @post = user, post)
  def allowed? = @user.editor? && @post.draft?
end
```

**Decorator / presenter** — adds view/display behavior to an object *without*
touching the model. A decorator wraps and forwards; a presenter is the same idea
focused on view formatting. Use plain Ruby + `SimpleDelegator`:

```ruby
class UserPresenter < SimpleDelegator
  def display_name = full_name.presence || email.split("@").first
  def joined = created_at.strftime("%b %Y")
end

UserPresenter.new(user).display_name   # forwards full_name/email to the wrapped user
```

Don't put `created_at.strftime(...)` logic in the model — display concerns belong in
the presenter/decorator layer.

## Result / Either objects vs exceptions for control flow

Use exceptions for *exceptional, unexpected* conditions. Use a **Result** object for
*expected* success/failure branches (validation fails, payment declined). Exceptions
as flow control are slow and hide the happy path.

```ruby
# WRONG — exceptions to model an expected outcome
def charge(order)
  raise PaymentDeclined unless gateway.ok?(order)
  ...
end
begin; charge(order); rescue PaymentDeclined; show_error; end

# RIGHT — explicit Result; both branches are visible at the call site
Result = Data.define(:success, :value, :error) do
  def self.success(value) = new(success: true, value:, error: nil)
  def self.failure(error) = new(success: false, value: nil, error:)
  def success? = success
  def on_success = (yield value if success?; self)
  def on_failure = (yield error unless success?; self)
end

result = Charge.new.call(order)
result.on_success { |receipt| notify(receipt) }
      .on_failure { |err| log(err) }
```

Pattern matching pairs beautifully with results (deconstruct → see
`references/language-idioms.md`):

```ruby
case Charge.new.call(order)
in { success: true, value: }   then redirect_to(value)
in { success: false, error: } then flash[:error] = error
end
```

For larger flows, the `dry-monads` gem (`Success`/`Failure`, `Do` notation) is the
idiomatic library choice — but a 10-line `Result` like above is often enough.

## Dependency injection in plain Ruby

No DI framework needed. Pass collaborators as keyword args with sensible defaults.
This keeps production wiring zero-config while making tests trivial.

```ruby
class ReportMailer
  def initialize(clock: Time, transport: SMTP.new)   # defaults = real objects
    @clock = clock
    @transport = transport
  end

  def send_daily
    @transport.deliver(at: @clock.now)
  end
end

# Test: inject fakes, no stubbing of globals
ReportMailer.new(clock: FrozenClock.new, transport: FakeTransport.new).send_daily
```

Do: default to the production object so callers write `ReportMailer.new`.
Don't: instantiate hard dependencies inside business methods, or reach for a global
`Container[:thing]` when a constructor arg does the job.

## Null Object pattern

Replace `nil`-checks scattered across the codebase with an object that answers the
same messages with do-nothing/neutral behavior. Honors LSP; removes `if x` noise.

```ruby
# WRONG — every caller must nil-check
user.account&.notify or default_notify

# RIGHT
class GuestUser
  def name = "Guest"
  def admin? = false
  def notify(*) = nil          # quietly does nothing
end

def current_user = session_user || GuestUser.new

current_user.name             # always safe, no &. needed
```

Caveat: a Null Object that *silently* swallows everything can mask bugs. Make it
explicit and narrow; don't `method_missing`-everything-to-nil.

## GoF patterns that are idiomatic in Ruby (and ones to skip)

Ruby's blocks/procs and open classes collapse several patterns to almost nothing.

**Strategy → a block or proc.** Don't build a class hierarchy for a one-method
strategy; pass a callable.

```ruby
# WRONG — Strategy-as-classes ceremony
class SumStrategy;  def apply(a) = a.sum; end
calc.strategy = SumStrategy.new

# RIGHT — the strategy IS a block
def calculate(items, &strategy) = strategy.call(items)
calculate(items) { |xs| xs.sum }
# or store a proc:
PRICERS = { flat: ->(o) { o.qty * 10 }, tiered: ->(o) { ... } }
PRICERS.fetch(plan).call(order)
```

**Observer → `Observable` / plain callbacks.** Use the stdlib `observer` mixin, or
just hold an array of subscribers (procs) and `each(&:call)`.

```ruby
class Publisher
  def initialize = @subs = []
  def subscribe(&blk) = @subs << blk
  def publish(event) = @subs.each { |s| s.call(event) }
end
```

**Adapter → a thin wrapper exposing the role you need.** Idiomatic and common
(e.g. wrapping a third-party client to present your app's interface).

```ruby
class SlackNotifier               # adapts Slack::Client to a #notify role
  def initialize(client) = @client = client
  def notify(msg) = @client.chat_postMessage(channel: "#ops", text: msg)
end
```

**Decorator → `SimpleDelegator`** (shown above). **Iterator → `Enumerable` + `each`**
(don't hand-roll). **Template Method → small inheritance with hook methods** (fine).

**Skip / avoid in Ruby:** Singleton-as-global-state (use a plain object passed in;
the `Singleton` mixin is rarely worth it). Abstract Factory / heavy Factory classes
(a method returning the right object, or a hash lookup, is enough). Visitor (usually
pattern matching is cleaner). Any pattern whose only job is to fake first-class
functions or interfaces — Ruby already has those.

## Cohesion, coupling, naming

- **High cohesion:** a class's methods and ivars all relate to one job. Methods that
  ignore the ivars (only touch their args) probably belong elsewhere or want to be a
  module function.
- **Low coupling:** depend on roles (duck types) and few of them. Count the
  collaborators a class names; more than ~3–4 concrete ones is a smell.
- **Connascence (the deep version of coupling):** prefer connascence of *name*
  (rename safely) over of *position* (use kwargs!) over of *meaning/algorithm*
  (magic numbers — extract a constant). Keep strong connascence *inside* one class.

```ruby
# WRONG — connascence of position; caller must remember the order
def schedule(user, time, retries, urgent); end
schedule(u, t, 3, true)

# RIGHT — connascence of name; order-independent, self-documenting
def schedule(user:, at:, retries: 0, urgent: false); end
schedule(user: u, at: t, urgent: true)
```

**Naming:** classes are nouns (`Invoice`, `PaymentGateway`); service objects can be
verb-phrases (`RegisterUser`, `ChargeOrder`). Methods asking a question end in `?`
and return boolean; mutating/bang methods end in `!`. Booleans read as predicates
(`active?` not `is_active`). Reveal *intent*, not implementation
(`overdue?` not `days_since_due > 30`). Avoid `Manager`/`Helper`/`Util`/`Data` class
names — they signal a missing abstraction.

## Refactoring before/after (full example)

```ruby
# BEFORE — fat method: validation, branching on type, persistence, email, all here
class OrdersController
  def create
    if params[:email] =~ /@/
      order = Order.new(params)
      if params[:kind] == "gift"
        order.total = order.items.sum(&:price) * 0.9
      else
        order.total = order.items.sum(&:price)
      end
      order.save
      Mailer.confirm(order.id, params[:email]).deliver_now
      redirect_to order
    else
      render :new
    end
  end
end
```

```ruby
# AFTER — controller stays skinny; logic lives in well-named collaborators
class OrdersController
  def create
    PlaceOrder.call(params: order_params)
      .on_success { |order| redirect_to order }
      .on_failure { render :new }
  end
end

class PlaceOrder
  def self.call(...) = new(...).call
  def initialize(params:, pricer: Pricer.for(params[:kind]), mailer: Mailer)
    @params, @pricer, @mailer = params, pricer, mailer
  end

  def call
    return Result.failure(:bad_email) unless @params[:email].to_s.include?("@")
    order = Order.create!(@params.merge(total: @pricer.call(@params)))
    @mailer.confirm(order).deliver_later
    Result.success(order)
  end
end

# Strategy as injected callable — no type branching in the use case
Pricer = Module.new
def Pricer.for(kind) = kind == "gift" ? ->(p){ subtotal(p) * 0.9 } : ->(p){ subtotal(p) }
```

What changed: SRP (controller orchestrates, service decides, pricer prices), DI
(mailer/pricer injected → testable), no `is_a?` branching (strategy proc), explicit
Result instead of nested `if`, Demeter respected.

## Quick checklist

- One reason to change per class; describe it without "and".
- Inject collaborators (kwargs, real-object defaults); don't `new` deep dependencies.
- Compose by default; inherit only for true, shallow *is-a* + substitutability.
- Modules = stateless roles; document the host interface they require; beware collisions.
- Duck-type on messages; avoid `is_a?`/`respond_to?` branching for flow.
- Tell, don't ask; obey Law of Demeter (delegate; chains OK only on Enumerable).
- Value objects → `Data.define` (immutable, value-equal). Mutable? then `Struct`.
- Service object: one public `#call`, returns a Result; logic lives in domain objects.
- Result/Either for *expected* failure; exceptions only for *exceptional* (`errors-and-types.md`).
- Null Object instead of scattered nil-checks (but keep it explicit, not magic).
- Strategy → block/proc; Observer → callbacks; Adapter → wrapper; skip Singleton/Visitor/heavy Factory.
- Prefer kwargs (connascence of name) over positional args; extract magic numbers.
- Names reveal intent; `?`/`!` conventions; avoid `Manager`/`Helper`/`Util`.
- Sandi's rules (100 lines / 5 lines / 4 params / 1 ivar-per-view) are tripwires — justify breaking them.
