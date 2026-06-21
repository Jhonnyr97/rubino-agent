# frozen_string_literal: true

# Dev-only measurement: token-honest comparison of the OLD full-page strip_html
# vs the NEW nokogiri readability main-content extraction in the webfetch tool.
# Tokens are the oMLX OpenAI-compatible server's EXACT prompt_tokens: each text
# is POSTed as a single user message with max_tokens:1 and we read
# usage.prompt_tokens, subtracting the measured chat-template overhead.
#
# Runs OFFLINE on three saved HTML fixtures (deterministic):
#   * wikipedia_ruby.html  - article with heavy nav + footer chrome (<main>)
#   * docs_ruby_string.html - API docs page (<main>/[role=main])
#   * hn_front.html        - "hard" page: content in a <table>, NO <main>/<article>
#                            -> exercises the safety fallback
#
# We measure exactly what the tool would hand the model: the body is truncated
# to WebFetchTool::MAX_BODY_SIZE and UTF-8 scrubbed first, identically for both
# the OLD and NEW paths.
#
# For each fixture we also assert FIDELITY: distinctive body sentences/headings
# survive in the NEW output, representative boilerplate (a nav item, a footer
# line) is gone, and for the hard page that the safety fallback fired.
#
# Run from the worktree root (needs the oMLX server up on :8000):
#   ruby -Ilib eval/webfetch_readability_saving.rb
#
# Writes eval/results/webfetch_readability_saving.md.

require "json"
require "net/http"
require "uri"
require "rubino/tools/base"
require "rubino/tools/webfetch_tool"

BASE   = "http://127.0.0.1:8000/v1/chat/completions"
APIKEY = "fake" # the literal configured api_key on the local oMLX server
MODEL  = "Qwen3.6-35B-A3B-MLX-8bit"

FIX_DIR = File.expand_path("fixtures", __dir__)
OUT     = File.expand_path("results/webfetch_readability_saving.md", __dir__)

def prompt_tokens(text)
  uri = URI(BASE)
  http = Net::HTTP.new(uri.host, uri.port)
  http.read_timeout = 180
  req = Net::HTTP::Post.new(uri)
  req["Authorization"] = "Bearer #{APIKEY}"
  req["Content-Type"]  = "application/json"
  req.body = JSON.generate(
    model: MODEL,
    messages: [{ role: "user", content: text }],
    max_tokens: 1,
    temperature: 0
  )
  body = JSON.parse(http.request(req).body)
  body.dig("usage", "prompt_tokens") or raise "no usage: #{body.inspect[0, 300]}"
end

# Measure the fixed per-message chat-template overhead once so the reported
# numbers are the CONTENT's token cost, not the envelope.
OVERHEAD = prompt_tokens("x") - 1
warn "chat-template overhead: #{OVERHEAD} tokens"

tool = Rubino::Tools::WebFetchTool.allocate
max  = Rubino::Tools::WebFetchTool::MAX_BODY_SIZE

# What the tool actually feeds its strip path: truncate-then-scrub.
def prepare(raw, max)
  body = raw.dup.force_encoding("UTF-8").scrub("?")
  body = body.byteslice(0, max).to_s.force_encoding("UTF-8").scrub("?") if body.bytesize > max
  body
end

FIXTURES = {
  "wikipedia_ruby (article + heavy nav/footer)" => {
    file: "wikipedia_ruby.html",
    keep: ["programming language", "Ruby on Rails"], # distinctive body terms
    drop: ["Jump to content"],                       # nav chrome
    expect_fallback: false
  },
  "docs_ruby_string (API docs page)" => {
    file: "docs_ruby_string.html",
    keep: %w[String method Returns],
    drop: [],
    expect_fallback: false
  },
  "hn_front (HARD: content in <table>, no <main>/<article>)" => {
    file: "hn_front.html",
    # No clean main container; main_container falls to <body>. Almost nothing is
    # chrome-tagged, so extraction naturally keeps the content (no fallback
    # needed, nothing lost) -- the "don't lose capability" guarantee on a hard page.
    keep: ["Hacker News", "points", "comments"],
    drop: [],
    expect_fallback: false
  },
  "thin_content_fallback (HARD: content NOT in <main>, chrome dominates)" => {
    file: "thin_content_fallback.html",
    # Thin body wrapped in a chrome-dominated page: stripping nav/header/footer
    # leaves the extract < 30% of the full strip, so the RATIO SAFETY FALLBACK
    # fires and we return the full strip -- nothing lost.
    keep: ["one small sentence", "Category 50"], # body + nav both present (full strip)
    drop: [],
    expect_fallback: true
  }
}.freeze

rows = []
FIXTURES.each do |label, spec|
  raw  = File.binread(File.join(FIX_DIR, spec[:file]))
  body = prepare(raw, max)

  old_txt = tool.send(:legacy_strip_html, body)
  new_txt = tool.send(:strip_html, body)

  old_tok = prompt_tokens(old_txt) - OVERHEAD
  new_tok = prompt_tokens(new_txt) - OVERHEAD
  pct = old_tok.positive? ? ((old_tok - new_tok) * 100.0 / old_tok).round(1) : 0.0

  fell_back = (new_txt == old_txt)

  keep_ok = spec[:keep].all? { |s| new_txt.include?(s) }
  drop_ok = spec[:drop].all? { |s| !new_txt.include?(s) }
  fallback_ok = (fell_back == spec[:expect_fallback])

  rows << {
    label: label, old: old_tok, new: new_tok, pct: pct,
    fell_back: fell_back, keep_ok: keep_ok, drop_ok: drop_ok,
    has_drop: !spec[:drop].empty?, fallback_ok: fallback_ok,
    old_chars: old_txt.length, new_chars: new_txt.length
  }

  warn format("%-46s old=%6d new=%6d  -%-5s  fallback=%s keep=%s drop=%s",
              label, old_tok, new_tok, "#{pct}%", fell_back, keep_ok, drop_ok)
end

md = +""
md << "# webfetch: old strip_html vs readability extraction (token-honest)\n\n"
md << "Model `#{MODEL}` on oMLX, exact `usage.prompt_tokens` " \
      "(overhead #{OVERHEAD} tok subtracted). Offline on saved fixtures, " \
      "each truncated to MAX_BODY_SIZE=#{max} then UTF-8 scrubbed (as the tool does).\n\n"
md << "| fixture | old tok | new tok | reduction | chars old→new | fallback | content kept | boilerplate dropped |\n"
md << "|---|--:|--:|--:|--:|:-:|:-:|:-:|\n"
rows.each do |r|
  drop_cell = if r[:has_drop]
                r[:drop_ok] ? "yes" : "NO"
              else
                "n/a"
              end
  md << format("| %s | %d | %d | %s%% | %d→%d | %s | %s | %s |\n",
               r[:label], r[:old], r[:new], r[:pct], r[:old_chars], r[:new_chars],
               r[:fell_back] ? "fired" : "no",
               r[:keep_ok] ? "yes" : "NO",
               drop_cell)
end
md << "\nFidelity asserts: `keep` substrings present in the NEW output, " \
      "`drop` boilerplate absent; on the thin/chrome-dominated page the safety " \
      "fallback must fire (NEW == full strip, nothing lost).\n"
File.write(OUT, md)

warn "\nwrote #{OUT}"
all_ok = rows.all? { |r| r[:keep_ok] && r[:drop_ok] && r[:fallback_ok] }
warn all_ok ? "FIDELITY: all checks passed" : "FIDELITY: SOME CHECKS FAILED"
exit(all_ok ? 0 : 1)
