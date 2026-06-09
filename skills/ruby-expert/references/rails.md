# Ruby on Rails — the Rails Way

Pragmatic, current Rails for **Ruby 3.2–3.4** and **Rails 7.1–8.x**. Optimize for convention, clarity, and safe production changes.

> **Precedence rule:** existing project conventions ALWAYS win. If the app already uses interactors, dry-rb, Trailblazer, or a custom layout, match it. The patterns below are defaults for greenfield or under-specified code.

## Convention over configuration & the app/ layout

Rails autoloads via **Zeitwerk**: file path ⇒ constant name. `app/services/billing/charge_card.rb` ⇒ `Billing::ChargeCard`. Don't `require` app code; let Zeitwerk resolve it. Don't fight the naming (`app/models/user.rb` ⇒ `User`).

```
app/
  models/        # Active Record + POROs that own domain data
    user.rb
    user/        # model-scoped concerns: User::Searchable -> app/models/user/searchable.rb
  controllers/   # skinny; HTTP <-> domain glue only
  services/      # service objects: one public #call
  jobs/          # ActiveJob subclasses
  mailers/
  views/
  components/    # ViewComponent, if used
  models/concerns/    # cross-model concerns (use sparingly)
  controllers/concerns/
```

Add your own top-level dirs (`app/queries`, `app/policies`, `app/forms`) freely — anything under `app/` is autoloaded.

## Active Record

### Associations

```ruby
class Post < ApplicationRecord
  belongs_to :author, class_name: "User"           # required by default (Rails 5+)
  has_many :comments, dependent: :destroy
  has_many :commenters, through: :comments, source: :user
  has_one :feature_flag
  has_many :tags, dependent: :delete_all           # skips callbacks; faster, use when no callbacks needed
end
```

- `dependent: :destroy` runs callbacks per row (N deletes). `:delete_all` is one SQL DELETE but skips callbacks. `:nullify` to orphan.
- `belongs_to` is `optional: false` by default — add `optional: true` for nullable FKs, don't just remove the validation.
- Use `inverse_of` when Rails can't infer it (custom `class_name`/`foreign_key`) to avoid loading the parent twice.
- Always back associations with a DB **foreign key** (`add_foreign_key`) — `dependent:` is app-level only.

### Validations

```ruby
validates :email, presence: true, uniqueness: { case_sensitive: false }
validates :state, inclusion: { in: %w[draft published] }
validate :publish_date_in_future, if: :published?
```

**Uniqueness validation has a race** — two requests can pass simultaneously. Always pair it with a **DB unique index**; rescue `ActiveRecord::RecordNotUnique` for the true guarantee.

### Scopes

```ruby
scope :published, -> { where(state: "published") }
scope :recent,    ->(n = 10) { order(created_at: :desc).limit(n) }

# Class method is equivalent and better when logic is non-trivial:
def self.for_account(account) = where(account: account)
```

A scope MUST return a relation (chainable). Guard conditional scopes: `scope :search, ->(q) { where("name ILIKE ?", "%#{q}%") if q.present? }` — returning `nil`/`all` keeps it chainable. Prefer `where.not`, `merge`, and named scopes over raw SQL fragments.

### Callbacks — minimize them

Callbacks create hidden control flow that fires on every save, breaks in bulk operations, and makes tests slow. **Default to NOT using them for business logic.**

```ruby
# AVOID: side effects buried in a callback
class Order < ApplicationRecord
  after_create :charge_customer, :send_receipt   # fires in tests, seeds, imports...
end

# PREFER: explicit orchestration in a service object
class PlaceOrder
  def call(order)
    order.save!
    ChargeCustomer.new.call(order)
    OrderMailer.receipt(order).deliver_later
  end
end
```

Acceptable callback uses: normalizing/deriving the record's **own** data (`before_validation` to downcase email), maintaining counters, setting defaults. Avoid callbacks that touch other records, send mail, enqueue jobs, or call external services. Never put `after_commit` chains across models — they become untraceable.

### Query interface

```ruby
User.where(active: true).where.not(role: "admin").order(:name)
User.where(id: ids)                 # IN (...)
User.where("age >= ?", 18)          # parameterized — never interpolate user input
Post.where(author: { admin: true }) # hash conditions across joins (Rails 7+)
User.where.missing(:posts)          # LEFT JOIN ... WHERE posts.id IS NULL
Order.where(created_at: 1.day.ago..) # endless range
```

Never string-interpolate user input into `where` — see `references/security.md` for SQL injection.

### Avoiding N+1: includes / preload / eager_load

```ruby
# N+1: one query per post for comments
Post.all.each { |p| p.comments.size }

# includes: Rails picks preload (2 queries) or eager_load (JOIN) automatically
Post.includes(:comments).each { |p| p.comments.size }

# Force the strategy when you need to:
Post.preload(:comments)            # always separate queries; can't filter on comments
Post.eager_load(:comments)         # always LEFT JOIN; needed to WHERE on the association
Post.includes(:comments).where(comments: { spam: false }).references(:comments)
```

Rule of thumb: `preload` (2 queries) is cheaper unless you must filter/order by the associated table, then use `eager_load`/`references`. Detect N+1 with the **bullet** gem or `prosopite`. Nested: `includes(comments: :author)`.

### select / pluck

```ruby
User.pluck(:email)                 # ["a@x.com", ...] — no model instantiation, fast
User.pluck(:id, :email)            # [[1, "a@x.com"], ...]
User.where(active: true).pick(:id) # first value only
User.select(:id, :email)           # ActiveRecord objects, only those columns loaded
User.sum(:balance)                 # aggregate in SQL, not Ruby
```

Use `pluck` for "just give me values"; `select` when you still need model behavior. Don't `User.all.map(&:email)` when `pluck(:email)` does it in one query.

### find_each / in_batches

```ruby
# Load 100k rows without blowing memory — batches of 1000 by default:
User.where(active: true).find_each { |u| u.recompute! }

User.in_batches(of: 500) do |relation|
  relation.update_all(synced_at: Time.current)   # one UPDATE per batch
end
```

`find_each` ignores `order` (it orders by primary key for cursoring). For bulk column updates use `update_all`/`in_batches` (no callbacks/validations) — see migration note below.

### Transactions & locking

```ruby
ApplicationRecord.transaction do
  account.withdraw!(amount)
  recipient.deposit!(amount)
  raise ActiveRecord::Rollback if fraud?   # rolls back without raising out
end
```

Gotchas: a transaction commits at the **outermost** block end; nested transactions don't roll back independently unless `requires_new: true`. **Never enqueue a job or call an external API inside a transaction** — use `after_commit`/`enqueue after commit` so you don't act on uncommitted (or rolled-back) data.

```ruby
# Optimistic locking: add a `lock_version` integer column; Rails raises on stale write
# StaleObjectError => reload & retry

# Pessimistic locking: SELECT ... FOR UPDATE, blocks other writers
Account.transaction do
  account = Account.lock.find(id)   # or .lock("FOR UPDATE NOWAIT")
  account.update!(balance: account.balance - amount)
end

product.with_lock { product.decrement!(:stock) }  # transaction + row lock
```

Use **optimistic** for low-contention web edits, **pessimistic** for money/inventory where you must serialize.

### Safe migrations (strong_migrations mindset)

A migration that locks a large table takes the app down. Use the **strong_migrations** gem and follow these:

```ruby
# DON'T: add NOT NULL column with default on a big table -> full table rewrite / lock (old PG)
add_column :users, :status, :string, null: false, default: "active"

# DO: nullable add, backfill in batches, then enforce
class AddStatus < ActiveRecord::Migration[7.2]
  disable_ddl_transaction!                 # required for CONCURRENTLY
  def change
    add_column :users, :status, :string    # nullable, no default
  end
end
# separate migration / rake task: backfill
User.in_batches(of: 5_000) { |b| b.update_all(status: "active") }
# then: change_column_null + add default in a later deploy
```

```ruby
# Indexes: build without locking writes
add_index :users, :email, algorithm: :concurrently, unique: true
```

Rules: **add columns nullable**, **backfill in batches** (never `update_all` a whole giant table in one statement under load), **add indexes `algorithm: :concurrently`** (with `disable_ddl_transaction!`), add NOT NULL/FK as `validate: false` then `validate_foreign_key`/`validate_check_constraint` separately, drop columns via `ignored_columns` first. Make migrations reversible (`change` or explicit `up`/`down`).

## Skinny controllers / rich models

```ruby
# AVOID: business logic in the controller
def create
  @order = Order.new(order_params)
  @order.total = @order.line_items.sum(&:price) * 1.08
  if @order.save
    Stripe::Charge.create(...)
    OrderMailer.receipt(@order).deliver_later
    redirect_to @order
  else
    render :new, status: :unprocessable_entity
  end
end

# PREFER: controller delegates to a service / model method
def create
  result = PlaceOrder.new.call(order_params)
  if result.success?
    redirect_to result.order, notice: "Order placed"
  else
    @order = result.order
    render :new, status: :unprocessable_entity
  end
end
```

Controllers should: parse params, invoke one domain call, set status/flash, render/redirect. Push everything else down. See `references/oo-design.md` for service/Result object shapes.

## RESTful routing & resources

```ruby
resources :posts do
  resources :comments, only: %i[create destroy], shallow: true
  member { post :publish }       # POST /posts/:id/publish
  collection { get :search }     # GET  /posts/search
end
resource :session, only: %i[new create destroy]   # singular: no :id
namespace :admin { resources :users }
```

Prefer the 7 standard actions; when you reach for many custom member routes, that's a sign a **new resource** is hiding (`posts/:id/publish` ⇒ consider `resources :publications`). Use `only:`/`except:` to keep the route table tight.

## Strong parameters

```ruby
def post_params
  params.require(:post).permit(:title, :body, tag_ids: [], meta: {})
end
```

`permit(:a, :b)` allowlists scalars; `tag_ids: []` permits an array; `meta: {}` permits an arbitrary hash (use cautiously). Never `permit!` user input. Rails 8 adds `params.expect(post: [:title, :body])` which raises a 400 on malformed structure — prefer it on Rails 8. See `references/security.md` for mass assignment.

## Concerns — done right and abused

`ActiveSupport::Concern` handles module dependencies and the `included do ... end` block.

```ruby
# app/models/post/publishable.rb  -> Post::Publishable (model-scoped concern)
module Post::Publishable
  extend ActiveSupport::Concern

  included do
    scope :published, -> { where.not(published_at: nil) }
    validates :published_at, presence: true, if: :published?
  end

  def publish!(now = Time.current) = update!(published_at: now)

  class_methods do
    def latest_published = published.order(published_at: :desc)
  end
end

class Post < ApplicationRecord
  include Publishable   # resolves to Post::Publishable
end
```

**Good concern:** cohesive, named after a capability (`Publishable`, `Archivable`), ideally model-scoped under `app/models/<model>/`, shared by ≥2 models or extracted to shrink a fat model meaningfully.

**Concern abuse:** a "concern" that's just a junk drawer; a concern only one model uses and that references private internals of the host (that's not reuse, it's hiding code); deep `included do` blocks that mutate the host in surprising ways. If a concern needs the host's guts and isn't reused, it's a candidate for a **service or value object** instead (see `references/oo-design.md`). Concerns share behavior; they don't reduce coupling.

## Service objects (app/services)

One public method, usually `#call`. Verb-named class. Returns a Result, not a boolean grab-bag.

```ruby
# app/services/orders/place_order.rb -> Orders::PlaceOrder
module Orders
  class PlaceOrder
    Result = Data.define(:order, :error) do
      def success? = error.nil?
    end

    def initialize(payments: Payments::Gateway.new) = @payments = payments  # inject collaborators

    def call(params)
      order = Order.new(params)
      Order.transaction do
        order.save!
        @payments.charge!(order)
      end
      Result.new(order:, error: nil)
    rescue ActiveRecord::RecordInvalid, Payments::Error => e
      Result.new(order:, error: e.message)
    end
  end
end
```

Inject dependencies via the constructor with sensible defaults (testable, no global mocks). Don't make services stateful across calls. See `references/oo-design.md` for Result/Either and `references/errors-and-types.md` for rescue discipline.

## ActiveJob & background jobs

```ruby
class SyncContactJob < ApplicationJob
  queue_as :default
  retry_on Net::OpenTimeout, wait: :polynomially_longer, attempts: 5
  discard_on ActiveJob::DeserializationError   # record was deleted; don't retry forever

  def perform(contact_id)
    contact = Contact.find_by(id: contact_id)
    return unless contact                       # idempotent: tolerate missing record
    CRM.upsert(contact)                          # this op must itself be idempotent
  end
end

SyncContactJob.perform_later(contact.id)
```

- **Pass IDs, not objects** — args are serialized; passing a record serializes a stale snapshot (`GlobalID` reloads it but adds a query; IDs are explicit and let you handle deletion).
- **Idempotency is mandatory** — jobs run at-least-once; a retry must not double-charge or double-send. Use unique keys / upserts / "already processed?" guards.
- **Retries:** `retry_on` for transient errors with backoff (`wait: :polynomially_longer`), `discard_on` for permanent ones. Cap attempts.
- **Queue choice:** separate latency-sensitive (`:mailers`, `:default`) from slow/bulk (`:low`, `:imports`) so a backlog of imports doesn't delay password-reset emails.
- **Backend:** **Solid Queue** (DB-backed, the Rails 8 default, no Redis) or **Sidekiq** (Redis, high throughput). Solid Queue ships in the default stack; pick Sidekiq when you need its throughput/ecosystem. Enqueue jobs **after commit**, not inside the transaction.

## Current attributes & request context

```ruby
# app/models/current.rb
class Current < ActiveSupport::CurrentAttributes
  attribute :user, :account, :request_id
end

# in ApplicationController
before_action { Current.user = authenticated_user }
```

`CurrentAttributes` is request/thread-local and **auto-reset after each request/job** — safe from leaking between requests. Use it for ambient context (current user, tenant, request id) to avoid threading them through every method. **Don't overuse it** as a global variable bus; it's still hidden global state and makes code harder to test. Never store it in jobs unless you re-set it from job args.

## Hotwire essentials (high level)

- **Turbo Drive:** intercepts links/forms, swaps `<body>` via fetch — SPA-like nav with zero JS. Forms that fail validation must render with `status: :unprocessable_entity` (422) or Turbo won't show the errors.
- **Turbo Frames:** `<turbo-frame id="x">` scopes navigation/updates to a region; a link inside replaces only that frame. Lazy-load with `src:`.
- **Turbo Streams:** server sends `append`/`prepend`/`replace`/`remove` actions over HTTP response or WebSocket (`turbo_stream_from`) to update specific DOM ids — used with `broadcasts_to` on models for live updates.
- **Stimulus:** small JS controllers (`data-controller`, `data-action`, targets) for sprinkles of behavior. Keep logic server-side; Stimulus glues DOM events to it.

Reach for Hotwire before a heavy SPA. See library docs for specifics; this file stays high-level.

## ActionMailer

```ruby
class OrderMailer < ApplicationMailer
  def receipt(order)
    @order = order
    mail(to: order.email, subject: "Your receipt")
  end
end

OrderMailer.receipt(order).deliver_later   # enqueue via ActiveJob; NOT deliver_now in requests
```

Use `deliver_later` so SMTP latency/failure doesn't block the request. Mailer previews under `test/mailers/previews`. Keep view logic in the mailer template; mailers are a thin adapter.

## Caching

```ruby
# Fragment + Russian-doll: nested fragments, inner key change busts only that fragment
<% cache @product do %>            # key includes updated_at -> auto-busts on change
  <% cache @product.vendor do %>   ...  <% end %>
<% end %>

# Low-level cache: expensive computation keyed yourself
Rails.cache.fetch("stats/#{account.id}", expires_in: 1.hour) do
  account.compute_expensive_stats
end
```

- Use `touch: true` on `belongs_to` so a child update bumps the parent's `updated_at` (drives Russian-doll invalidation).
- Cache keys should encode everything that affects output (model + `cache_version`/`updated_at`); never hand-roll keys that can go stale.
- **Solid Cache** is the Rails 8 default store (DB-backed). For per-request memoization use a method-level `||=` or `Current`, not the cache store.

## Secure defaults

- **CSRF:** `protect_from_forgery` is on by default for non-GET HTML; keep it. API-only controllers use token auth instead.
- **Strong params:** never `permit!`; allowlist explicitly (above).
- **Params filtering / logging:** `config.filter_parameters += [:password, :token, :ssn]` so secrets don't hit logs. Rails seeds common ones.
- **Encrypted credentials:** `bin/rails credentials:edit` ⇒ `config/credentials.yml.enc` + `master.key` (gitignored). Read with `Rails.application.credentials.dig(:stripe, :secret_key)`. Don't put secrets in `config/*.yml` or commit `master.key`.
- **Active Record Encryption** for column-level encryption of PII (`encrypts :ssn`).
- **Force SSL:** `config.force_ssl = true` in production.

Deeper vuln coverage (SQLi, XSS, mass assignment, SSRF, Brakeman) lives in `references/security.md`.

## Quick checklist

- Existing project conventions override every default here.
- Let Zeitwerk autoload; name files to match constants; don't `require` app code.
- Back every association/uniqueness rule with a real DB constraint (FK, unique index).
- Minimize callbacks; move side effects (mail, jobs, external calls) into service objects.
- Kill N+1 with `includes`/`preload`; use `eager_load`+`references` only to filter on the join.
- Use `pluck`/`select`/aggregates instead of loading-then-mapping in Ruby.
- `find_each`/`in_batches` for large sets; `update_all` for bulk column writes (no callbacks).
- Wrap multi-row writes in transactions; enqueue jobs and call APIs **after commit**, never inside.
- Pick optimistic (low contention) vs pessimistic (`lock`/`with_lock`, money/inventory) locking deliberately.
- Safe migrations: nullable add → batch backfill → enforce; indexes `algorithm: :concurrently` + `disable_ddl_transaction!`.
- Skinny controllers: parse params, one domain call, render/redirect; 422 on failed Turbo forms.
- Strong params allowlist only; `params.expect` on Rails 8; never `permit!`.
- Concerns must be cohesive and reused; otherwise prefer a service/value object.
- Service objects: verb name, one `#call`, inject collaborators, return a Result.
- Jobs: pass IDs, be idempotent, `retry_on`/`discard_on` with capped backoff, separate queues; Solid Queue or Sidekiq.
- `CurrentAttributes` for request context — but it's still global state; use sparingly.
- `deliver_later` for mail; Russian-doll caching with `touch: true`; `Rails.cache.fetch` for low-level.
- Keep credentials encrypted, filter params from logs, keep CSRF on; security depth in `references/security.md`.
