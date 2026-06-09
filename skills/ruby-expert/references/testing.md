# Testing — RSpec, Minitest, TDD

Test **behavior, not implementation**. A test should survive a refactor that keeps behavior identical. If you rename a private method and a test breaks, the test was coupled to implementation. Assert on observable outputs, return values, raised errors, and side effects you actually care about — not on which internal methods got called (unless the interaction *is* the contract, e.g. "enqueues a job").

## TDD red-green-refactor

1. **Red** — write the smallest failing test for the next bit of behavior. Run it; confirm it fails for the *right* reason.
2. **Green** — write the least code to pass. Hardcode if needed.
3. **Refactor** — clean up with tests green. Don't add behavior here.

Keep cycles tiny. The discipline buys you a regression net and forces testable design (DI, small objects — see `references/oo-design.md`).

```ruby
# Red: describe the behavior you want before it exists
RSpec.describe Discount do
  it "applies 10% off orders over 100" do
    expect(Discount.new(rate: 0.10).apply(120)).to eq(108)
  end
end
```

## RSpec structure & naming

- `describe` a class/method; `context` a condition; `it` one behavior.
- Method conventions: `describe "#instance_method"`, `describe ".class_method"`.
- `context` strings start with "when"/"with"/"without". `it` reads as a sentence after "it".

```ruby
RSpec.describe Order do
  describe "#total" do
    context "when it has line items" do
      it "sums the line item subtotals" do
        # ...
      end
    end

    context "when empty" do
      it "returns zero" do
        # ...
      end
    end
  end
end
```

### let, let!, subject

`let` is **lazy + memoized per example**. `let!` forces eager evaluation in a `before` hook (use when the record must exist even if no example references it). `subject` names the thing under test.

```ruby
RSpec.describe Invoice do
  subject(:invoice) { Invoice.new(amount: 100, currency: "USD") }

  let(:customer) { build(:customer) }        # lazy: built only when referenced
  let!(:audit)   { create(:audit_log) }      # eager: row exists before each example

  it { is_expected.to be_valid }             # uses subject

  it "formats the amount" do
    expect(invoice.formatted).to eq("$100.00")
  end
end
```

**Don't** overuse `let` for "mystery guest" data scattered across the file. If a value only matters in one example, declare it inline — locality beats DRY in tests.

```ruby
# WRONG: forces reader to scroll up to understand the example
let(:role) { "admin" }
it("permits deletes") { expect(policy(role)).to be_allowed }

# RIGHT: the relevant data is right here
it "permits deletes for admins" do
  expect(policy("admin")).to be_allowed
end
```

### Hooks

`before(:each)` (default) runs per example; `before(:all)`/`before(:context)` runs once — avoid it for DB state (leaks between examples, not rolled back by transactional fixtures). `after` for cleanup that `ensure`-style needs guaranteeing.

## Expectations & built-in matchers

```ruby
expect(value).to eq(5)                    # ==  (value equality)
expect(value).to be(obj)                  # equal? (same object identity)
expect(result).to be_truthy / be_nil / be_present
expect(list).to include(2, 3)             # subset / substring / hash pair
expect(list).to contain_exactly(3, 1, 2)  # same elements, ANY order
expect(list).to match_array([1, 2, 3])    # alias of contain_exactly
expect(str).to match(/\Aord_\w+\z/)       # regex / nested structure
expect(user).to have_attributes(name: "Ada", admin: false)
expect(hash).to match(id: kind_of(Integer), name: a_string_matching(/x/))

# Predicate magic: be_<predicate> calls value.<predicate>?
expect(user).to be_admin                  # => user.admin?
expect(order).to be_a_kind_of(Order)

# change matcher — assert a side effect, by/from-to
expect { post.publish! }
  .to change(post, :status).from("draft").to("published")
expect { create(:user) }.to change(User, :count).by(1)
expect { noop }.not_to change(User, :count)

# raising
expect { parse("oops") }.to raise_error(ParseError, /unexpected/)
expect { parse("oops") }.to raise_error(ParseError) { |e| expect(e.line).to eq(3) }

# composing matchers
expect(response).to include("ok").and have_attributes(status: 200)
expect(numbers).to all(be > 0)
```

Prefer `eq` over `==` assertions; prefer `contain_exactly` over sorting both sides; prefer the predicate form (`be_valid`) over `eq(true)` on a boolean method.

### aggregate_failures

By default an example stops at the first failure. `aggregate_failures` reports *all* failures in the block — great for API response assertions so you fix everything in one run.

```ruby
it "returns the created user" do
  aggregate_failures do
    expect(response).to have_http_status(:created)
    expect(json[:name]).to eq("Ada")
    expect(json[:id]).to be_present
  end
end
```

## Doubles, stubbing, mocking

**Verifying doubles** (`instance_double`, `class_double`, `object_double`) check that the stubbed methods actually exist with the right arity on the real class. **Always prefer them** — a plain `double` will happily stub a method that was renamed/deleted, giving green tests against dead code.

```ruby
# WRONG: passes even after PaymentGateway#charge is renamed
gateway = double("gateway", charge: true)

# RIGHT: fails loudly if #charge no longer exists / wrong arity
gateway = instance_double(PaymentGateway, charge: true)
```

### allow vs expect

`allow` = stub (set up a canned return, no requirement it's called). `expect` = mock (it *must* be called, fails otherwise). Use `expect` only when the call is the behavior you're verifying.

```ruby
# stub a query/collaborator return
allow(clock).to receive(:now).and_return(Time.utc(2026, 1, 1))

# mock a command you assert happens (and with what args)
expect(mailer).to receive(:deliver).with(hash_including(to: "a@b.com")).once

# return values, sequences, raising
allow(api).to receive(:fetch).and_return(:first, :second) # successive calls
allow(api).to receive(:fetch).and_raise(Timeout::Error)
allow(api).to receive(:fetch) { |id| cache[id] }          # compute from args
```

### Spies (assert-after-the-fact)

Spies let you Arrange-Act-Assert without the awkward expect-before-act ordering. Use `spy` or `have_received`.

```ruby
notifier = instance_spy(SlackNotifier)
service = Deployer.new(notifier:)

service.run                                  # Act

expect(notifier).to have_received(:post).with("deployed").once  # Assert
```

**Don't** mock what you don't own deeply (HTTP libs, ActiveRecord internals). Wrap third parties in a thin adapter and mock *your* adapter — or stub at the network boundary (below).

## Mocking external HTTP — WebMock / VCR

Never hit real networks in tests (slow, flaky, non-deterministic). Block all real connections and stub explicitly.

```ruby
# spec/support/webmock.rb
require "webmock/rspec"
WebMock.disable_net_connect!(allow_localhost: true) # localhost for Capybara

it "fetches the rate" do
  stub_request(:get, "https://api.fx.test/usd")
    .with(query: { to: "eur" }, headers: { "Authorization" => "Bearer t" })
    .to_return(status: 200, body: { rate: 0.9 }.to_json,
               headers: { "Content-Type" => "application/json" })

  expect(FxClient.new.rate("eur")).to eq(0.9)
  expect(a_request(:get, /api.fx.test/)).to have_been_made.once
end
```

VCR records a real interaction once into a "cassette" and replays it. Good for complex third-party flows; **filter secrets** and avoid letting cassettes hide real contract drift (re-record periodically).

```ruby
VCR.configure do |c|
  c.cassette_library_dir = "spec/cassettes"
  c.hook_into :webmock
  c.filter_sensitive_data("<TOKEN>") { ENV["API_TOKEN"] }
  c.default_cassette_options = { record: :none } # CI must not record
end

it "lists charges", :vcr do  # cassette named from example
  expect(Stripe::Charge.list.size).to eq(3)
end
```

## Time control

Frozen/relative time prevents clock-flakiness. Rails ships `ActiveSupport::Testing::TimeHelpers` (`travel_to`, `freeze_time`, `travel_back`); non-Rails projects can use the `timecop` gem.

```ruby
# Rails (preferred — no extra gem)
RSpec.configure { |c| c.include ActiveSupport::Testing::TimeHelpers }

travel_to(Time.utc(2026, 6, 9, 12)) do
  expect(Token.new.expires_at).to eq(Time.utc(2026, 6, 9, 13))
end

freeze_time do
  record.touch
  expect(record.updated_at).to eq(Time.current)
end

# plain Ruby
Timecop.freeze(Time.utc(2026)) { ... }
```

**Don't** assert against `Time.now` without freezing — `eq(Time.now)` races. Inject a clock (`clock: Time` default) for pure-Ruby objects; see DI in `references/oo-design.md`.

## Custom matchers, shared examples & contexts

Custom matcher for repeated, intention-revealing assertions:

```ruby
RSpec::Matchers.define :be_a_valid_slug do
  match { |str| str.match?(/\A[a-z0-9-]+\z/) }
  failure_message { |str| "expected #{str.inspect} to be a valid slug" }
end

expect(post.slug).to be_a_valid_slug
```

Shared examples = reusable behavior contracts (e.g. every `Searchable`). Shared context = reusable setup.

```ruby
RSpec.shared_examples "a timestamped record" do
  it { is_expected.to respond_to(:created_at, :updated_at) }
end

RSpec.describe Comment do
  subject { build(:comment) }
  it_behaves_like "a timestamped record"
end

RSpec.shared_context "authenticated", :auth do
  let(:current_user) { create(:user) }
  before { sign_in(current_user) }
end

RSpec.describe "Dashboard", :auth do  # pulls in the context via tag
  # current_user + sign_in available
end
```

## Tags & focus

```ruby
it("slow path", :slow) { ... }
# run a subset: rspec --tag slow ; exclude: rspec --tag ~slow
```

`fit`/`fdescribe`/`fcontext` (or `:focus`) restrict the run to focused examples — handy locally. **Never commit focus**; configure `config.filter_run_when_matching :focus` and add a RuboCop/CI guard so a stray `fit` fails the build (CI config lives in `references/tooling.md`).

## FactoryBot — build the lightest thing that works

Prefer, in order: `build_stubbed` > `build` > `create`. Only `create` when you truly need a persisted row (queries, DB constraints, associations loaded from DB).

```ruby
FactoryBot.define do
  factory :user do
    sequence(:email) { |n| "user#{n}@example.com" }   # unique values
    name { "Ada" }

    trait :admin do
      role { "admin" }
    end

    # association: only created when the strategy needs it
    factory :author do
      association :profile
    end
  end
end
```

```ruby
build_stubbed(:user)  # in-memory, fake id, NO DB hit — fastest; great for unit/policy specs
build(:user)          # in-memory, not saved (associations may still touch DB)
create(:user, :admin) # persisted, with trait
create_list(:post, 3, author: user)
```

### Avoid factory cascades

A factory whose associations create more factories which create more rows = slow, brittle tests. Keep factories **minimal and valid** (only attributes required for validity). Pass collaborators explicitly instead of letting the factory deep-create them.

```ruby
# WRONG: creating a comment silently inserts a post + user + account...
create(:comment)

# RIGHT: share parents, create only what the test needs
post = create(:post)
create(:comment, post:)
```

Use `traits` for variation, not a forest of named factories. Run `FactoryBot.lint` in CI to catch factories that no longer build valid records.

## Database state — transactional fixtures vs database_cleaner

For most specs use Rails' **transactional fixtures** (`config.use_transactional_fixtures = true` in `rspec-rails`): each example runs in a transaction rolled back at the end — fast and isolated. **System/feature specs** that run the app in a separate thread/process (Capybara + real browser) can't see uncommitted transaction data, so use `database_cleaner` with the `:truncation` (or `:deletion`) strategy for those, and `:transaction` elsewhere.

```ruby
DatabaseCleaner.strategy = :transaction
RSpec.configure do |c|
  c.before(:each, type: :system) { DatabaseCleaner.strategy = :truncation }
  c.around(:each) { |ex| DatabaseCleaner.cleaning { ex.run } }
end
```

## The test pyramid — which spec type to favor

Lots of fast **unit specs** (models, services, POROs, values), fewer integration, very few end-to-end.

- **Model specs** — validations, scopes, methods. Fast.
- **Service / PORO specs** — your business logic; the bulk of value. Inject collaborators, stub the boundaries.
- **Request specs** (`type: :request`) — full controller stack via real HTTP (`get/post`, assert status + JSON/body). **Favor these over controller specs** (deprecated style) for API/HTTP coverage.
- **Job specs** — `expect { Thing.perform_later }.to have_enqueued_job`; test `perform` logic directly and idempotency.
- **Mailer specs** — assert recipients, subject, body, and that mail is enqueued/delivered.
- **System specs** (`type: :system`, Capybara, headless Chrome via `selenium`/`cuprite`) — true browser, JS, multi-page flows. Slow and most flake-prone; keep to critical happy paths only.

```ruby
# request spec
RSpec.describe "POST /api/users", type: :request do
  it "creates a user" do
    expect { post "/api/users", params: { user: { name: "Ada" } } }
      .to change(User, :count).by(1)
    expect(response).to have_http_status(:created)
  end
end

# job spec
RSpec.describe ChargeJob do
  include ActiveJob::TestHelper
  it "enqueues on the payments queue" do
    expect { ChargeJob.perform_later(1) }
      .to have_enqueued_job.on_queue("payments").with(1)
  end
end

# mailer spec
it "emails the user" do
  expect { UserMailer.welcome(user).deliver_now }
    .to change { ActionMailer::Base.deliveries.size }.by(1)
  expect(ActionMailer::Base.deliveries.last.to).to eq([user.email])
end
```

(Rails app layout/types: `references/rails.md`.)

## Coverage — use SimpleCov wisely

Coverage shows *unexecuted* lines, not *untested behavior*. 100% line coverage with no assertions proves nothing. Use it to find blind spots, not as a target to game.

```ruby
# spec/spec_helper.rb (very top, before app code loads)
require "simplecov"
SimpleCov.start "rails" do
  add_filter "/spec/"
  enable_coverage :branch   # branch coverage catches untested conditionals
end
```

## Minitest equivalent

For projects on Minitest (Rails default). Assertion style:

```ruby
require "test_helper"

class OrderTest < ActiveSupport::TestCase
  test "totals line items" do
    order = orders(:one)              # fixtures
    assert_equal 108, order.total
    assert order.valid?
    refute order.empty?
    assert_includes order.tags, "vip"
    assert_nil order.coupon
    assert_raises(ArgumentError) { order.apply(nil) }
    assert_difference("Order.count", 1) { Order.create!(...) }
    assert_changes -> { order.status }, from: "draft", to: "open" do
      order.open!
    end
  end
end
```

Spec-style (`Minitest::Spec`) reads like RSpec-lite:

```ruby
require "minitest/autorun"
describe Discount do
  it "applies a rate" do
    _(Discount.new(0.1).apply(120)).must_equal 108
  end
end
```

Mocking with built-in `Minitest::Mock` and `stub`:

```ruby
mock = Minitest::Mock.new
mock.expect(:charge, true, [100])          # method, return, expected args
service.run(gateway: mock)
mock.verify                                 # fails if not called as specified

gateway.stub(:online?, true) do            # temporary stub within block
  assert service.available?
end
```

For richer mocking/time helpers add `mocha` and `timecop`; `assert_enqueued_with`, `travel_to`, `assert_emails` ship with Rails' test helpers.

## Fast, deterministic, isolated — and avoiding flakes

Common flaky-test causes and fixes:

- **Time** — never assert on `Time.now`; freeze/travel time. Beware DST and `Time.zone` vs `Time.now`.
- **Ordering** — `contain_exactly`/`match_array`, never assume DB row order without `ORDER BY`. Run `rspec --order random` (the default `--seed`) so order-dependence surfaces.
- **Shared/global state** — leaking class vars, memoized singletons, `ENV`, `Thread.current`, registered observers, or `before(:all)` DB rows. Reset between examples.
- **Randomness** — seed `srand`, or inject the RNG; stub `SecureRandom`/`S-equence`.
- **External I/O** — block the network (WebMock), don't read real clocks/files; stub the boundary.
- **Async/system specs** — use Capybara's auto-waiting matchers (`have_content`), never `sleep`; let it retry until timeout.
- **Test interdependence** — each example must pass in isolation: `rspec path/to/spec.rb:42`. If it only passes with the whole file, you have leakage.

```ruby
# WRONG: order-dependent and sleep-based
sleep 2
expect(page.text).to include("Saved")     # races the render

# RIGHT: auto-waiting assertion retries until matched or timeout
expect(page).to have_content("Saved")
```

Keep tests **independent** (no example relies on another), **deterministic** (same result every run), and **fast** (push logic into POROs you can unit-test without the DB/HTTP stack).

## Quick checklist

- Test behavior and public contracts, not private methods or call sequences.
- Red → green → refactor in small steps; watch the test fail first.
- `instance_double`/verifying doubles over plain `double`, always.
- `allow` for stubs (queries), `expect`/`have_received` for commands you assert.
- Prefer `build_stubbed` > `build` > `create`; keep factories minimal; avoid cascades.
- Stub the network (WebMock/VCR); never hit real services; filter secrets.
- Freeze/travel time; never assert against live `Time.now`.
- Use `contain_exactly` for unordered collections; run specs in random order.
- Request specs over controller specs; keep system specs to critical paths only.
- `aggregate_failures` for multi-assertion API checks.
- No committed `fit`/`fdescribe`/focus; no `sleep` in system specs — use auto-waiting matchers.
- Coverage (SimpleCov, branch) finds gaps; it is not a quality target.
- Each example must pass in isolation; reset global/shared state.
- Rails app layout → `references/rails.md`; CI & RuboCop config → `references/tooling.md`.
