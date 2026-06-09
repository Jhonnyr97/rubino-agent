# Dates, times, time zones & text encoding

Ruby 3.2–3.4 / Rails 7.1–8.x. Two independent topics that share a theme: **the default is rarely what you want, and the bug is silent.** Always be explicit about zone and encoding.

---

## PART 1 — Dates, times & time zones

### `Time` vs `Date` vs `DateTime`

| Class | Use for | Notes |
|---|---|---|
| `Time` | timestamps, instants, anything with hours/minutes | Nanosecond precision, zone-aware. **Default choice.** |
| `Date` | calendar dates with no time-of-day (birthdays, due dates) | No zone, no time. |
| `DateTime` | **legacy — avoid in new code** | Slower, subtle calendar-reform quirks, superseded by `Time`. |

```ruby
# DON'T introduce DateTime in new code
DateTime.now            # WRONG: legacy class
# DO
Time.current            # RIGHT (Rails, zone-aware)
Time.now                # plain Ruby instant (system zone — see footgun below)
```

If a library hands you a `DateTime`, convert: `datetime.to_time`.

### The #1 Rails footgun: system zone vs app zone

`Time.now`, `Date.today`, `Time.at`, `Time.parse` use the **server's system zone** (`ENV["TZ"]`). In Rails you almost always want the **application zone** (`Time.zone`). They differ silently until production runs in a different zone than your laptop.

```ruby
# WRONG — system zone, leaks server config into your data/logic
Time.now
Date.today
Time.now.beginning_of_day

# RIGHT — application zone (ActiveSupport::TimeWithZone)
Time.current            # == Time.zone.now
Date.current            # == Time.zone.today
Time.zone.now.beginning_of_day
Time.zone.local(2026, 6, 9, 14, 30)
Time.zone.at(epoch_seconds)
Time.zone.parse("2026-06-09 14:30")
```

Rule: in a Rails app, if you typed `Time.now` or `Date.today`, it's a bug. Use `Time.current` / `Date.current` / `Time.zone.*`. (The `rubocop-rails` cop `Rails/TimeZone` enforces this.)

`Time.current` returns an `ActiveSupport::TimeWithZone` — quacks like `Time` but carries the zone. Comparisons across zones work because they normalize to UTC internally.

### `config.time_zone` vs `config.active_record.default_timezone`

Two **different** settings, frequently confused:

```ruby
# config/application.rb
config.time_zone = "America/Lima"          # the app's DISPLAY zone (Time.zone)
config.active_record.default_timezone = :utc  # how AR STORES/reads DB times
```

- `config.time_zone` = what `Time.zone` / `Time.current` return; how times are presented to users.
- `config.active_record.default_timezone` = `:utc` (default & recommended) or `:local`; controls the zone AR assumes for DB columns.

**Store UTC, display local.** Keep DB in UTC (`:utc`), set `config.time_zone` to your users' zone, and let `TimeWithZone` convert at the edges. A user can also have a per-request zone:

```ruby
around_action :use_user_zone
def use_user_zone(&block)
  Time.use_zone(current_user&.time_zone || "UTC", &block)
end
```

### Parsing safely

`Time.parse` is convenient and dangerous: it **raises** on garbage, is lenient/ambiguous, and is locale-influenced. Never feed it raw user input unguarded.

```ruby
# WRONG — raises ArgumentError on bad input, ambiguous formats
Time.parse(params[:when])

# RIGHT — explicit format, fail closed
def parse_when(str)
  Time.zone.strptime(str, "%Y-%m-%d %H:%M")   # zone-aware, exact format
rescue ArgumentError, TypeError
  nil
end
```

Prefer strict parsers when the format is known:

```ruby
Time.iso8601("2026-06-09T14:30:00-05:00")  # strict ISO 8601, raises on non-ISO
Date.iso8601("2026-06-09")
Time.zone.iso8601("2026-06-09T14:30:00Z")  # -> TimeWithZone (Rails)
Time.at(1_749_500_000)                      # epoch seconds -> system zone
Time.zone.at(1_749_500_000)                 # epoch -> app zone (preferred in Rails)
Time.at(1_749_500_000.123456, in: "+00:00")
```

Guidelines:
- Known machine format → `iso8601` / `strptime` with an explicit pattern.
- Epoch integer → `Time.at` (or `Time.zone.at`).
- Free-form human input → validate/normalize upstream; if you must use `Time.parse`, wrap in `rescue ArgumentError`.

### Formatting — `strftime` cheatsheet

```ruby
t.strftime("%Y-%m-%d")          # 2026-06-09   (year-month-day)
t.strftime("%H:%M:%S")          # 14:30:05     (24h:min:sec)
t.strftime("%Y-%m-%dT%H:%M:%S%z") # 2026-06-09T14:30:05-0500
```

| Code | Means | Code | Means |
|---|---|---|---|
| `%Y` | 4-digit year | `%H` | hour 00–23 |
| `%m` | month 01–12 | `%M` | minute 00–59 |
| `%d` | day 01–31 | `%S` | second 00–59 |
| `%A` | weekday name (Monday) | `%z` | UTC offset `-0500` |
| `%B` | month name (June) | `%j` | day of year |
| `%p` | AM/PM | `%:z` | offset `-05:00` |

Don't hand-roll ISO strings — use the built-ins:

```ruby
t.iso8601                       # "2026-06-09T14:30:05-05:00"
t.to_fs(:iso8601)               # Rails: same, via to_formatted_string
t.utc.iso8601                   # normalize to UTC first when serializing
```

In Rails, prefer **I18n** for human-facing output (locale-aware, not hardcoded):

```ruby
I18n.l(Time.current, format: :short)   # uses config/locales/*.yml :time formats
I18n.l(Date.current, format: :long)
# define :short/:long under time.formats / date.formats in your locale files
```

### Arithmetic & durations

Use ActiveSupport durations and calendar helpers — they're DST-aware:

```ruby
2.hours.ago                     # TimeWithZone, app zone
3.days.from_now
Time.current.beginning_of_day
Time.current.end_of_month
date + 1.day                    # calendar-correct
(start..finish).to_a            # range of dates
```

```ruby
# WRONG — treats a day as a fixed 86400s; breaks across DST
t + 86400
t + (24 * 60 * 60)

# RIGHT — calendar day, DST-aware
t + 1.day
t.tomorrow
t.advance(days: 1)
```

Plain Ruby arithmetic is in **seconds** and is fine for true elapsed seconds, but never use it to mean "the next calendar day."

### DST & ambiguity

Daylight Saving creates two hazards:
- **Spring-forward gap:** a wall-clock time that never existed (02:30 may not occur).
- **Fall-back overlap:** a wall-clock time that occurs twice (01:30 happens twice).

Defenses:
- **Compare and store in UTC.** Offsets and durations are unambiguous in UTC.
- Do arithmetic with ActiveSupport durations (`+ 1.day`), which respect DST.
- Convert at boundaries with `in_time_zone` / `change` carefully:

```ruby
t.utc                           # normalize before comparing/storing
t.in_time_zone("America/Lima")  # reinterpret instant in another zone (same UTC instant)
Time.current.in_time_zone("UTC")

# WRONG: comparing two local times across a DST boundary
local_a < local_b
# RIGHT: compare the underlying instants
local_a.utc < local_b.utc       # (TimeWithZone#<=> already does this; force_zone bugs don't)
```

`in_time_zone` keeps the same instant and changes the display zone. Don't confuse it with `change(...)` (which mutates fields and can land you in a DST gap).

### Monotonic clock for measuring elapsed time

Wall-clock time can jump (NTP, DST, manual change). To measure **durations**, use the monotonic clock — it only moves forward.

```ruby
# WRONG — wall clock can go backward; can yield negative/garbage durations
start = Time.now
do_work
elapsed = Time.now - start

# RIGHT — monotonic
start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
do_work
elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start  # seconds (Float)
```

Use `Time`/`Time.current` for *what time it is*; use `CLOCK_MONOTONIC` for *how long something took*.

### Testing time

Freeze/travel with `ActiveSupport::Testing::TimeHelpers` (`travel_to`, `freeze_time`, `travel`) instead of stubbing `Time.now`. See `references/testing.md` for setup and patterns — not repeated here.

---

## PART 2 — String encoding & text

### UTF-8 is the default

Modern Ruby is UTF-8 end to end: source files, string literals, and `Encoding.default_external` are UTF-8 unless something overrides them. You rarely need a `# encoding:` magic comment anymore.

```ruby
Encoding.default_external   # usually #<Encoding:UTF-8> (from locale/ENV)
Encoding.default_internal   # usually nil (no auto-transcode on read)
"café".encoding             # #<Encoding:UTF-8>
"café".valid_encoding?      # true
```

### `force_encoding` vs `encode` — the classic bug

This is the single most common encoding mistake.

- **`encode`** = *transcode*: convert the actual bytes from one encoding to another. Bytes change, characters preserved.
- **`force_encoding`** = *relabel*: reinterpret the **same bytes** under a different encoding tag. Bytes unchanged; meaning may break.

```ruby
# encode: real conversion (UTF-8 -> ISO-8859-1 bytes)
"café".encode("ISO-8859-1")            # bytes re-encoded

# force_encoding: just changes the label, NO byte conversion
bytes = "café".dup.force_encoding("ASCII-8BIT")  # now treated as raw bytes
bytes.force_encoding("UTF-8")          # back to UTF-8 label, original bytes intact
```

```ruby
# WRONG — "fixing" a mojibake by relabeling; produces invalid strings
response_body.force_encoding("UTF-8")   # when bytes are actually Latin-1
# RIGHT — transcode from the real source encoding
response_body.encode("UTF-8", "ISO-8859-1")
```

Use `force_encoding` only when you *know* the bytes are already in the target encoding but were mislabeled (e.g., a string read in binary mode that you know is UTF-8). Use `encode` to actually convert.

### Conversion errors & scrubbing

Two errors you'll hit:
- `Encoding::UndefinedConversionError` — a character has no representation in the target encoding.
- `Encoding::InvalidByteSequenceError` — bytes aren't valid in the source encoding.

```ruby
# Replace un-mappable / invalid bytes instead of raising
clean = raw.encode("UTF-8", invalid: :replace, undef: :replace)
clean = raw.encode("UTF-8", invalid: :replace, undef: :replace, replace: "?")

# scrub: drop/replace invalid bytes, staying in the same encoding
"bad\xFFstring".scrub             # "bad�string"
"bad\xFFstring".scrub("")         # remove them
str.valid_encoding?               # check before trusting
```

`String#scrub` is the quickest way to make an untrusted UTF-8 string safe to log/store. For a transcode you also want `invalid:`/`undef:`.

### Bytes vs characters — `ASCII-8BIT` / BINARY

`ASCII-8BIT` (alias `BINARY`) means "this is raw bytes, not text." Use it for binary protocols, hashing, image data, etc.

```ruby
"\xDE\xAD".b                       # ASCII-8BIT literal (raw bytes)
File.binread("logo.png")           # ASCII-8BIT, no transcode
io = File.open(path, "rb")         # binary mode
digest = Digest::SHA256.digest(bytes)  # operate on bytes
```

Work in **bytes** for I/O boundaries, crypto, and length-prefixed protocols; work in **characters** for anything user-facing text.

### Length, slicing, normalization

```ruby
"café".length        # 4  (characters / code points)
"café".size          # 4  (alias)
"café".bytesize      # 5  (UTF-8: é is 2 bytes)
"café".byteslice(0, 3)   # slice by BYTES (can split a multibyte char!)
"café"[0, 3]             # slice by CHARACTERS -> "caf"
```

Don't assume one char == one byte. For truncating to a byte budget (DB column, network frame), use `byteslice` then `scrub` to repair a possibly-split tail character.

**Unicode normalization** — "é" can be one code point (NFC) or `e` + combining accent (NFD). They look identical but aren't `==`. Normalize before comparing user input, filenames (esp. macOS, which uses NFD), or building dedupe keys:

```ruby
a = "café"                  # could be NFC or NFD depending on source
a.unicode_normalize(:nfc)   # canonical composed form (default; use for comparison/storage)
a.unicode_normalize(:nfd)   # decomposed
a.unicode_normalized?(:nfc) # boolean check
```

Pick **NFC** as your canonical form on the way in.

### Reading/writing files with explicit encoding

Be explicit at the I/O boundary; don't rely on the process default.

```ruby
File.read(path, encoding: "UTF-8")
File.write(path, str)                       # writes in str's encoding
File.open(path, "r:UTF-8") { |f| f.read }
File.open(path, "r:BOM|UTF-8") { |f| ... }  # strip a leading UTF-8 BOM
File.open(path, "rb") { |f| f.read }        # raw bytes (ASCII-8BIT)

# external:internal — transcode on read
File.open(path, "r:ISO-8859-1:UTF-8") { |f| f.read }  # read Latin-1, hand back UTF-8
```

`"BOM|UTF-8"` handles the byte-order-mark that Windows/Excel exports often prepend — without it the BOM (`﻿`) sneaks into your first field/line.

### External data: CSV & HTTP

```ruby
require "csv"
# Tell CSV the file's real encoding (Excel often emits Windows-1252 or BOM'd UTF-8)
CSV.foreach(path, encoding: "bom|utf-8", headers: true) { |row| ... }
CSV.read(path, encoding: "ISO-8859-1:UTF-8")   # transcode while parsing
```

HTTP bodies arrive as bytes; the client may tag them `ASCII-8BIT` or guess wrong. Re-tag/transcode from the response's declared `charset`:

```ruby
# If you KNOW the bytes are UTF-8 but they're labeled binary:
body = response.body.dup.force_encoding("UTF-8")
body = body.scrub unless body.valid_encoding?
# If charset says something else, TRANSCODE instead:
body = response.body.encode("UTF-8", "Shift_JIS")
```

Decide: are the bytes already UTF-8 (relabel with `force_encoding`) or in another charset (convert with `encode`)? Getting this wrong is the mojibake bug.

### Symbols & frozen strings

Encoding interacts with frozen-string literals and symbol interning, but those topics live elsewhere: see `references/language-idioms.md` (string/symbol idioms, `frozen_string_literal`) and `references/performance.md` (allocation/interning cost, parse cost of repeated `Time.parse`/`encode`). For Active Record column storage and zone config in the DB, see `references/rails.md`.

---

## Quick checklist

- Rails: use `Time.current` / `Date.current` / `Time.zone.*` — never `Time.now` / `Date.today`.
- New code: use `Time` or `Date`; never `DateTime`.
- Store times in **UTC** (`default_timezone = :utc`), display in `config.time_zone`. "Store UTC, display local."
- Parse with explicit formats: `iso8601` / `strptime`; wrap `Time.parse` in `rescue ArgumentError`, never trust raw input.
- Add `1.day`, not `86400` — durations are DST-aware; raw seconds are not.
- Compare/serialize across zones in **UTC**; convert display with `in_time_zone`.
- Measure elapsed time with `Process.clock_gettime(Process::CLOCK_MONOTONIC)`, never `Time.now - Time.now`.
- Test time with `travel_to` / `freeze_time` (see `references/testing.md`).
- `encode` = convert bytes; `force_encoding` = relabel bytes. Don't relabel to "fix" mojibake.
- Scrub untrusted text: `encode("UTF-8", invalid: :replace, undef: :replace)` or `String#scrub`; check `valid_encoding?`.
- Use `bytesize`/`byteslice` for byte budgets, `length`/`[]` for characters — one char ≠ one byte.
- Normalize user input/filenames to **NFC** with `unicode_normalize(:nfc)` before comparing.
- At I/O boundaries be explicit: `File.read(path, encoding: "UTF-8")`, `"r:BOM|UTF-8"`, `"rb"` for raw bytes.
- CSV/HTTP: know the source charset; `bom|utf-8` for Excel exports; transcode (`encode`) when charset ≠ UTF-8.
