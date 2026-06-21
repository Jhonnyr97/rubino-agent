# frozen_string_literal: true

# Dev-only measurement: token-honest PER-TYPE check of the unified
# Compression::ContentRouter. For each fixture we run the router (config ON) and
# confirm it ROUTES to the right strategy, then measure FULL vs ROUTED tokens via
# the oMLX OpenAI-compatible server's exact prompt_tokens (max_tokens:1 →
# usage.prompt_tokens, minus the chat-template overhead). The point is to prove:
#   log/test/build  → compressed (~big saving)
#   grep / diff     → PASSTHROUGH, byte-identical (0%)
#   code whole-file → skeleton
#   short           → untouched
#
# Run from the worktree root (needs the oMLX server up on :8000):
#   ruby -Ilib eval/router_per_type.rb
#
# Writes eval/results/router_per_type.md.

require "json"
require "net/http"
require "uri"
require "rubino"

BASE   = "http://127.0.0.1:8000/v1/chat/completions"
APIKEY = "fake" # the literal configured api_key on the local oMLX server
MODEL  = "Qwen3.6-35B-A3B-MLX-8bit"

def prompt_tokens(text)
  uri = URI(BASE)
  http = Net::HTTP.new(uri.host, uri.port)
  http.read_timeout = 180
  req = Net::HTTP::Post.new(uri)
  req["Authorization"] = "Bearer #{APIKEY}"
  req["Content-Type"]  = "application/json"
  req.body = JSON.generate(model: MODEL, messages: [{ role: "user", content: text }], max_tokens: 1)
  JSON.parse(http.request(req).body).dig("usage", "prompt_tokens")
end

OVERHEAD = prompt_tokens("").to_i
puts "chat-template overhead: #{OVERHEAD} tokens"

# Configure the router exactly as `setup` would (master flag + both sub-configs).
cfg = Rubino.configuration
cfg.set("tool_output_compression", "enabled", true)
cfg.set("tool_output_compression", "code",
        "strategy" => "skeleton", "min_lines" => 150, "keep_method_body_max_lines" => 8)
cfg.set("tool_output_compression", "logs",
        "enabled" => true, "min_lines" => 40, "max_total_lines" => 100,
        "max_errors" => 10, "max_warnings" => 5, "max_stack_traces" => 3, "context_lines" => 4)
cfg.set("tool_output_compression", "diff",
        "context_lines" => 3, "min_lines" => 40, "min_saving" => 0.25,
        "generated_patterns" => Rubino::Compression::DiffCompressor::DEFAULT_GENERATED)
cfg.set("tool_output_compression", "json",
        "min_items" => 8, "min_lines" => 40, "min_saving" => 0.25,
        "outlier_sigma" => 3.0, "max_string_chars" => 400)

router = Rubino::Compression::ContentRouter.new(cfg)

def read_fixture(name) = File.read(File.join(__dir__, "fixtures", name))

# Each case: [label, expected_type, tool_name, text, hint]
CODE_SRC = File.read(File.join(__dir__, "fixtures", "code_tool_executor.rb"))
CASES = [
  ["rspec suite (21 failures)", :log,  "shell", -> { read_fixture("rspec_full.txt") }, {}],
  ["rubocop (750 files)",       :log,  "shell", -> { read_fixture("rubocop_full.txt") }, {}],
  ["git diff -U25 (large, 9 files)", :diff, "shell", -> { read_fixture("diff_large.txt") }, { stream_kind: :diff }],
  ["package-lock.json diff",    :diff, "shell", -> { read_fixture("diff_lockfile.txt") }, { stream_kind: :diff }],
  ["small diff (version bump)", :diff, "shell", -> { read_fixture("diff_small.txt") }, { stream_kind: :diff }],
  ["grep defs (50 hits)",       :grep, "grep",  -> { read_fixture("grep_defs.txt") }, {}],
  ["code whole-file read",      :code, "read",  -> { CODE_SRC },
   { full_file: true, content_type: :code, source_path: "tool_executor.rb", raw_source: CODE_SRC }],
  ["short output (3 lines)",    :short, "shell", -> { "build ok\n2 files\ndone" }, {}],
  # JSON channel — a whole-output JSON dump from `shell` routes to :json (BEFORE
  # :log). Large uniform arrays fold; the small JSON passes through.
  ["gh api issues (100, uniform)", :json, "shell", -> { read_fixture("json_gh_issues.json") }, {}],
  ["kubectl pods (100, +err/outlier)", :json, "shell", -> { read_fixture("json_kubectl_pods.json") }, {}],
  ["docker inspect (1 big object)", :json, "shell", -> { read_fixture("json_big_object.json") }, {}],
  ["small JSON (health check)", :json, "shell", -> { read_fixture("json_small.json") }, {}]
].freeze

rows = CASES.map do |label, expected, tool, text_fn, hint|
  original = text_fn.call
  result = router.route(original, tool_name: tool, compress_hint: hint)
  routed  = result.applied? ? result.text : original
  type_ok = result.content_type == expected

  full_tok = prompt_tokens(original).to_i - OVERHEAD
  comp_tok = prompt_tokens(routed).to_i - OVERHEAD
  reduction = full_tok.zero? ? 0.0 : (full_tok - comp_tok).fdiv(full_tok) * 100
  identical = !result.applied? && routed == original

  puts format("%-28s route=%-6s expect=%-6s %-8s full=%6d routed=%6d  -%.1f%%%s",
              label, result.content_type, expected, type_ok ? "OK" : "MISROUTE",
              full_tok, comp_tok, reduction, identical ? "  [byte-identical]" : "")

  { label: label, expected: expected, got: result.content_type, type_ok: type_ok,
    applied: result.applied?, full: full_tok, comp: comp_tok, reduction: reduction,
    identical: identical, strategy: result.strategy }
end

md = +"# Per-type routing — token measurement (oMLX, exact prompt_tokens)\n\n"
md << "Model: `#{MODEL}` · server `http://127.0.0.1:8000/v1` · "
md << "chat-template overhead subtracted (#{OVERHEAD} tok).\n"
md << "Router: `Rubino::Compression::ContentRouter` (the unified seam).\n\n"
md << "| Output | Routed → | Correct? | Full tok | Routed tok | Reduction | Passthrough byte-identical |\n"
md << "|---|---|---|---:|---:|---:|---|\n"
rows.each do |r|
  pt = if r[:applied]
         "—"
       else
         (r[:identical] ? "YES ✅" : "NO ❌")
       end
  md << format("| %s | %s | %s | %d | %d | %.1f%% | %s |\n",
               r[:label], "#{r[:got]} (#{r[:strategy]})", r[:type_ok] ? "✅" : "❌ (#{r[:expected]})",
               r[:full], r[:comp], r[:reduction], pt)
end
all_routed = rows.all? { |r| r[:type_ok] }
pass_identical = rows.reject { |r| r[:applied] }.all? { |r| r[:identical] }
routing_note = all_routed ? "every fixture routed to the expected strategy. ✅" : "MISROUTE — see table. ❌"
fidelity_note = if pass_identical
                  "every passthrough output is byte-identical to its input. ✅"
                else
                  "BROKEN — see table. ❌"
                end
md << "\nRouting: #{routing_note}\n"
md << "Passthrough fidelity: #{fidelity_note}\n"

# --- JSON fidelity: error/outlier rows survive BOTH the lossless fold and the
# forced-lossy path; small JSON is byte-identical. (Byte-level, no LLM.) -------
jc_cfg = { "min_items" => 8, "min_lines" => 40, "min_saving" => 0.25,
           "outlier_sigma" => 3.0, "max_string_chars" => 400 }
pods = read_fixture("json_kubectl_pods.json")
lossless = Rubino::Compression::JsonCompressor.new(jc_cfg).compress(pods)
lossy = Rubino::Compression::JsonCompressor.new(jc_cfg.merge("min_saving" => 0.85)).compress(pods)
small_in = read_fixture("json_small.json")
small_out = router.route(small_in, tool_name: "shell")

md << "\n## JSON fidelity (byte-level, no LLM)\n\n"
md << "| Check | Result |\n|---|---|\n"
md << format("| lossless fold keeps the error row (`CrashLoopBackOff`) | %s |\n",
             lossless.text.include?("back-off 5m0s") ? "✅" : "❌")
md << format("| lossless fold keeps the outlier (`restarts: 9999`) | %s |\n",
             lossless.text.include?("9999") ? "✅" : "❌")
md << format("| lossless fold ratio | %.1f%% |\n", lossless.ratio * 100)
md << format("| LOSSY (forced) STILL keeps the error row | %s |\n",
             lossy.text.include?("back-off 5m0s") ? "✅" : "❌")
md << format("| LOSSY STILL keeps the outlier | %s |\n", lossy.text.include?("9999") ? "✅" : "❌")
md << format("| LOSSY drops the rest behind `{\"_elided\": N}` | %s |\n",
             lossy.text.match?(/\{"_elided":\d+\}/) ? "✅" : "❌")
md << format("| LOSSY ratio (kept %d rows) | %.1f%% |\n",
             lossy.text.lines.count { |l| l.include?("|") }, lossy.ratio * 100)
small_routed = small_out.applied? ? small_out.text : small_in
md << format("| small JSON passes through byte-identical | %s |\n",
             !small_out.applied? && small_routed == small_in ? "✅" : "❌")

out = File.join(__dir__, "results", "router_per_type.md")
File.write(out, md)
puts "\nwrote #{out}"
