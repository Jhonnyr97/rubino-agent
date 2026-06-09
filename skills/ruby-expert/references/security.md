# Security

Secure Ruby/Rails for an AI agent. Each vuln class shows the unsafe pattern next to the safe one. Targets Ruby 3.2–3.4, Rails 7.1–8.x. For app structure see references/rails.md; for the `send` injection note see references/metaprogramming.md; for regex performance (separate from ReDoS) see references/performance.md.

## SQL injection

Never interpolate user input into SQL fragments. Use parameterized queries — hash conditions, placeholders, or `sanitize_sql`.

```ruby
# WRONG — string interpolation, trivially injectable
User.where("name = '#{params[:name]}'")
User.where("age > #{params[:age]}")
Order.order(params[:sort])                     # order() is also injectable

# RIGHT — hash conditions (auto-parameterized + quoted)
User.where(name: params[:name])
User.where("age > ?", params[:age])            # positional placeholder
User.where("age > :age", age: params[:age])    # named placeholder
```

Column names and SQL keywords can't be parameterized — allowlist them.

```ruby
# WRONG — user controls the column/direction
Order.order("#{params[:col]} #{params[:dir]}")

# RIGHT — allowlist, never pass raw input as identifiers
SORTS = { "name" => "name", "date" => "created_at" }.freeze
col = SORTS.fetch(params[:col], "created_at")
dir = params[:dir] == "desc" ? "desc" : "asc"
Order.order(Arel.sql("#{col} #{dir}"))         # Arel.sql asserts you vetted it
```

`Arel.sql` silences Rails' "dangerous raw SQL" deprecation — only wrap values you have already proven safe. Other injectable methods that take raw SQL: `select`, `group`, `having`, `joins`, `pluck`, `lock`, `from`. The same hash/placeholder rules apply. `find_by_sql`/`execute` need `sanitize_sql_array`:

```ruby
sql = User.sanitize_sql_array(["SELECT * FROM users WHERE name = ?", params[:name]])
User.find_by_sql(sql)
```

## Command injection

A string command goes through the shell, so metacharacters (`;`, `|`, `` ` ``, `$()`) inject. The array form bypasses the shell entirely.

```ruby
# WRONG — shell interpolation
system("convert #{params[:file]} out.png")
`git log #{ref}`
%x{ping #{host}}
exec("rm -rf #{dir}")

# RIGHT — array/multi-arg form: no shell, args passed literally
system("convert", params[:file], "out.png")
out = IO.popen(["git", "log", ref], &:read)
system("ping", "-c", "1", host)
```

`open`, `Open3.capture2/capture3`, `IO.popen`, `spawn`, `Process.spawn`, `Kernel#exec/system` all take the array form. Prefer `Open3` for capturing output safely:

```ruby
require "open3"
stdout, stderr, status = Open3.capture3("git", "log", "--oneline", ref)
```

Never pass untrusted input to `eval`, `instance_eval`, `class_eval`, `Kernel#open` with a `"|cmd"` string, or `send`/`public_send` with a user-supplied method name (see references/metaprogramming.md).

## Mass assignment

Use strong parameters; permit explicitly. Never `permit!` user input.

```ruby
# WRONG — user can set admin: true, role:, etc.
User.create(params[:user])
User.update(params.require(:user).permit!)

# RIGHT — explicit allowlist; sensitive attrs never permitted
def user_params
  params.require(:user).permit(:name, :email, :bio)
end
User.create(user_params)
```

Defense in depth for truly sensitive columns — block assignment at the model:

```ruby
class User < ApplicationRecord
  attr_readonly :account_id          # set once, never via update
  # or expose a guarded setter and keep role= private
end
```

Nested/array params must be declared:

```ruby
params.require(:order).permit(:note, line_items: [:sku, :qty], tag_ids: [])
```

## Unsafe deserialization

`Marshal.load`, `YAML.load` (pre-3.1 behavior), and `Oj` in object mode can instantiate arbitrary classes and trigger RCE. Never feed them untrusted bytes.

```ruby
# WRONG — RCE on attacker-controlled input
Marshal.load(request.body.read)
YAML.load(params[:config])

# RIGHT — safe_load with an explicit class allowlist
YAML.safe_load(params[:config])                            # only basic types
YAML.safe_load(file, permitted_classes: [Date, Symbol], aliases: false)

# Prefer JSON for untrusted data
JSON.parse(request.body.read)                              # objects only, no code
```

On Ruby 3.1+/Psych 4, `YAML.load` is already an alias for `safe_load`; use `YAML.unsafe_load` only for files you fully control (and even then, prefer not to). Avoid `Marshal` for any cross-trust boundary — it has no safe mode.

## XSS in Rails

ERB auto-escapes by default. The danger is anything that opts out: `html_safe`, `raw`, `<%==`, and `sanitize` misuse.

```erb
<%# RIGHT — auto-escaped, safe %>
<%= @user.bio %>

<%# WRONG — renders raw HTML from user input %>
<%= raw @user.bio %>
<%= @user.bio.html_safe %>
<%== @user.bio %>
```

When you must allow some HTML, use `sanitize` with an allowlist — never `html_safe`:

```erb
<%= sanitize @post.body, tags: %w[p br strong em a], attributes: %w[href] %>
```

Other XSS sinks:

```ruby
# WRONG — user data into a script/JS context
"<script>var u = '#{params[:name]}';</script>".html_safe
# RIGHT
content_tag(:script, "var u = #{params[:name].to_json};".html_safe)  # to_json escapes

link_to "site", params[:url]            # WRONG: javascript: URLs execute
# RIGHT — validate scheme
url = params[:url].to_s
link_to "site", (url.start_with?("http://", "https://") ? url : "#")
```

Set a Content-Security-Policy (`config/initializers/content_security_policy.rb`) as a backstop. `html_safe` does not sanitize — it only marks a string as already-safe; calling it on user input is the bug.

## CSRF

Rails enables CSRF protection by default. Keep it on.

```ruby
class ApplicationController < ActionController::Base
  protect_from_forgery with: :exception   # default on new apps; don't remove
end
```

Don't `skip_forgery_protection` or `skip_before_action :verify_authenticity_token` on state-changing actions. For JSON APIs authenticated by token/header (not cookies), use `ActionController::API` (no cookie session → CSRF N/A) rather than disabling the check on a cookie-session controller. Never globally disable it to "fix" a failing form.

## Open redirects

`redirect_to` with user input lets attackers bounce victims to phishing sites.

```ruby
# WRONG — open redirect
redirect_to params[:return_to]

# RIGHT — Rails 7+ blocks off-host redirects by default; be explicit
redirect_to params[:return_to], allow_other_host: false   # default
# Or allowlist paths only
safe = params[:return_to].to_s
redirect_to(safe.start_with?("/") && !safe.start_with?("//") ? safe : root_path)
```

Rails 7 made `allow_other_host: false` the default and raises on cross-host targets — do not set `allow_other_host: true` with user input.

## Authorization / IDOR

Insecure Direct Object Reference: a user passes an `id` for a record they don't own. Scope every lookup to the current user, and enforce a policy layer.

```ruby
# WRONG — any user can read any invoice
@invoice = Invoice.find(params[:id])

# RIGHT — scope to ownership; 404s on someone else's record
@invoice = current_user.invoices.find(params[:id])
```

Use a policy library and verify on every action:

```ruby
# Pundit
class InvoicePolicy < ApplicationPolicy
  def show? = record.user_id == user.id
end

def show
  @invoice = Invoice.find(params[:id])
  authorize @invoice            # raises Pundit::NotAuthorizedError if denied
end
# enforce it globally
after_action :verify_authorized, except: :index
```

CanCanCan equivalent uses `authorize! :show, @invoice` against an `Ability`. Don't rely on hidden form fields or "the UI doesn't show it" — always check server-side. Don't trust `params[:user_id]` for the actor; derive identity from the session/token.

## Secrets management

Never commit secrets. Use Rails encrypted credentials or ENV; keep the master key out of git.

```bash
EDITOR="code --wait" bin/rails credentials:edit            # edits config/credentials.yml.enc
# config/master.key (and *.key) MUST be gitignored; ship the key via ENV in prod
```

```ruby
Rails.application.credentials.dig(:stripe, :secret_key)   # decrypted at runtime
ENV.fetch("DATABASE_URL")                                 # fetch → fails loudly if unset
```

```ruby
# WRONG — secret hardcoded / committed
STRIPE_KEY = "sk_live_abc123"
ENV["SECRET"] || "fallback-secret"                        # fallback leaks into source
```

Use the `dotenv-rails` gem for local dev ENV (gitignore `.env`, commit `.env.example` with blank values). Per-environment credentials: `config/credentials/production.yml.enc` + `config/credentials/production.key`. If a key leaks, rotate it — don't just remove it from the latest commit (it stays in history).

## Dependency security

Audit gems for known CVEs and keep them patched.

```bash
gem install bundler-audit
bundle audit check --update         # checks Gemfile.lock against ruby-advisory-db
```

Run `bundle audit` in CI and fail the build on findings. Enable Dependabot (`.github/dependabot.yml`) or Renovate for automated PRs. Pin sources and avoid arbitrary git/path gems from untrusted origins:

```ruby
source "https://rubygems.org"                  # use HTTPS; don't add random sources
gem "rails", "~> 7.2.0"                         # pessimistic constraint, see tooling.md
gem "nokogiri", "~> 1.16"
```

Commit `Gemfile.lock` (apps) so CI/prod resolve identical versions. Review transitive deps; prefer well-maintained gems. For high-assurance setups, verify gem signatures (`gem cert` / `--trust-policy`), though most of the ecosystem is unsigned — rely primarily on the advisory DB + lockfile pinning. See references/tooling.md for Bundler details and references/gem-authoring.md for publishing.

## Static analysis — Brakeman

Brakeman is a Rails-specific security scanner; run it in CI.

```bash
gem install brakeman
brakeman --no-pager                 # scan
brakeman -w2 -z                      # warning level 2+, exit non-zero on findings (CI)
brakeman -I                          # interactively build the ignore file
```

Triage findings into `config/brakeman.ignore` (with a note/justification per entry) for vetted false positives; never blanket-ignore. Pair with RuboCop's security cops. Brakeman catches SQLi, command injection, mass assignment, unsafe redirects, and `html_safe`/`raw` XSS sinks statically — but it is not a substitute for the safe patterns above.

## ReDoS and Timeout

Catastrophic backtracking lets a short input hang a regex (and your request thread). The risk is nested/overlapping quantifiers on user input.

```ruby
# WRONG — exponential backtracking on "aaaaaa!"
/^(a+)+$/ =~ user_input
/(\w+\s*)+$/ =~ user_input

# RIGHT — avoid nested quantifiers; anchor with \A \z (not ^ $, which match per-line)
/\A\w+\z/ =~ user_input
```

Ruby 3.2+ ships a regexp timeout — set a global cap so no single match can hang:

```ruby
Regexp.timeout = 1.0                              # seconds, global (Ruby 3.2+)
/\A(a+)+\z/.match?(input, timeout: 0.5)           # per-regexp override
```

Validate input length before matching, and prefer non-regex parsing where possible. (Regex *performance/backtracking* internals: references/performance.md.) For other untrusted-duration work, `Timeout.timeout` exists but is unsafe — it can raise at arbitrary points and corrupt state; prefer the native regexp timeout or IO/socket-level timeouts instead.

## Random tokens and constant-time comparison

Use `SecureRandom` (CSPRNG) for anything secret — never `rand`, `Random`, or `SecureRandom.random_number` mod small ranges for tokens.

```ruby
# WRONG — predictable
token = rand(10**10).to_s
token = Time.now.to_i.to_s(36)

# RIGHT
SecureRandom.hex(32)          # 64 hex chars
SecureRandom.urlsafe_base64(32)
SecureRandom.uuid             # for ids, not secrets
```

Compare secrets/tokens in constant time to avoid timing attacks — `==` short-circuits and leaks length/prefix info.

```ruby
# WRONG — early-exit comparison leaks timing
provided == stored_token

# RIGHT — constant-time
ActiveSupport::SecurityUtils.secure_compare(provided, stored_token)         # equal-length
ActiveSupport::SecurityUtils.fixed_length_secure_compare(a, b)
# plain Ruby:
OpenSSL.fixed_length_secure_compare(a, b)   # raises unless same length; hash first if not
```

Store password hashes with `has_secure_password` (bcrypt) — never plain or fast hashes (MD5/SHA) for passwords.

## TLS / certificate verification

Never disable certificate verification. It silently enables MITM.

```ruby
# WRONG — accepts any cert
http.verify_mode = OpenSSL::SSL::VERIFY_NONE
Net::HTTP.start(host, 443, use_ssl: true, verify_mode: OpenSSL::SSL::VERIFY_NONE)
OpenSSL::SSL::VERIFY_NONE   # anywhere with untrusted peers

# RIGHT — verify (the default); use https URIs
uri = URI("https://api.example.com")
Net::HTTP.get(uri)                         # verifies by default
http = Net::HTTP.new(uri.host, uri.port)
http.use_ssl = true                        # verify_mode defaults to VERIFY_PEER
```

If you hit cert errors, fix the trust store (`ssl_ca_cert`/`SSL_CERT_FILE`) — don't disable verification. Same rule for HTTP client gems (Faraday/HTTParty/Excon): never set `verify: false`/`ssl_verify: false` in production.

## SSRF

Server-Side Request Forgery: user-controlled URLs let attackers reach internal services (cloud metadata `169.254.169.254`, `localhost`, private ranges).

```ruby
# WRONG — fetches whatever the user points at
Net::HTTP.get(URI(params[:url]))

# RIGHT — allowlist scheme + host, then resolve and block private IPs
require "resolv"; require "ipaddr"

def safe_fetch(raw)
  uri = URI.parse(raw)
  raise "scheme" unless %w[http https].include?(uri.scheme)
  raise "host"   unless ALLOWED_HOSTS.include?(uri.host)   # allowlist is strongest
  ip = IPAddr.new(Resolv.getaddress(uri.host))
  raise "private" if ip.private? || ip.loopback? || ip.link_local?
  Net::HTTP.get(uri)
end
```

Prefer an explicit host allowlist over a denylist. Beware DNS-rebinding (resolve-then-connect on the same IP) and redirects (disable auto-follow or re-validate each hop). Block link-local (`169.254.0.0/16`) to protect cloud metadata endpoints.

## File uploads and path traversal

`../` in a filename can escape your directory. Never build paths from raw user input.

```ruby
# WRONG — path traversal: "../../etc/passwd"
File.read(File.join("uploads", params[:file]))
File.read("uploads/#{params[:name]}")

# RIGHT — basename strips directories; verify the result stays inside the root
name = File.basename(params[:file])                 # drops any path components
path = File.expand_path(File.join(UPLOAD_DIR, name))
raise "traversal" unless path.start_with?(UPLOAD_DIR + File::SEPARATOR)
File.read(path)
```

For uploads: allowlist extensions and validate content type, cap size, store outside the web root (or use Active Storage), and generate your own filename (`SecureRandom`) rather than trusting the client's.

```ruby
ALLOWED_EXT = %w[.png .jpg .jpeg .pdf].freeze
ext = File.extname(uploaded.original_filename).downcase
raise "type" unless ALLOWED_EXT.include?(ext)
stored = "#{SecureRandom.uuid}#{ext}"
```

Validate by sniffing real content (e.g. `Marcel`/magic bytes), not just the extension or the client-supplied MIME type. Never `send_file`/`render file:` with a user-controlled path without the basename+root check above.

## Quick checklist

- SQLi: `where(col: val)` / `where("x = ?", val)`; never interpolate; allowlist column/order identifiers; `Arel.sql` only on vetted strings.
- Command: array form `system("cmd", arg)` / `Open3.capture3`; never string commands, backticks, or `eval` with input.
- Mass assignment: strong params with explicit `permit`; never `permit!` user data; guard sensitive columns at the model.
- Deserialization: `YAML.safe_load` / `JSON.parse` on untrusted input; never `Marshal.load` or `YAML.unsafe_load` across trust boundaries.
- XSS: rely on auto-escaping; `sanitize` with allowlist, never `raw`/`html_safe` on user input; `to_json` for JS contexts; set CSP.
- CSRF: keep `protect_from_forgery`; use `ActionController::API` for token APIs instead of disabling it.
- Redirects: keep `allow_other_host: false`; allowlist or require leading `/`.
- AuthZ/IDOR: scope finds via `current_user.things.find`; enforce Pundit/CanCanCan on every action; verify server-side.
- Secrets: encrypted credentials or `ENV.fetch`; gitignore `*.key`/`.env`; rotate on leak; no hardcoded fallbacks.
- Deps: `bundle audit` in CI; Dependabot; commit `Gemfile.lock`; HTTPS source; pessimistic version pins.
- Scan: Brakeman `-w2 -z` in CI; triage into `brakeman.ignore` with justifications.
- ReDoS: avoid nested quantifiers; anchor with `\A\z`; set `Regexp.timeout`.
- Tokens: `SecureRandom`; compare with `SecurityUtils.secure_compare`; `has_secure_password` for passwords.
- TLS: never `VERIFY_NONE` / `verify: false`; fix the CA store instead.
- SSRF: allowlist scheme+host, resolve and block private/loopback/link-local IPs, re-validate redirects.
- Files: `File.basename` + `expand_path` + root prefix check; allowlist extension and sniff content; generate the stored filename.
