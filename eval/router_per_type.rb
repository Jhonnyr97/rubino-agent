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

router = Rubino::Compression::ContentRouter.new(cfg)

def read_fixture(name) = File.read(File.join(__dir__, "fixtures", name))

# Each case: [label, expected_type, tool_name, text, hint]
CODE_SRC = File.read(File.join(__dir__, "fixtures", "code_tool_executor.rb"))
CASES = [
  ["rspec suite (21 failures)", :log,  "shell", -> { read_fixture("rspec_full.txt") }, {}],
  ["rubocop (750 files)",       :log,  "shell", -> { read_fixture("rubocop_full.txt") }, {}],
  ["git diff (executor)",       :diff, "shell", -> { read_fixture("git_diff.txt") }, { stream_kind: :diff }],
  ["grep defs (50 hits)",       :grep, "grep",  -> { read_fixture("grep_defs.txt") }, {}],
  ["code whole-file read",      :code, "read",  -> { CODE_SRC },
   { full_file: true, content_type: :code, source_path: "tool_executor.rb", raw_source: CODE_SRC }],
  ["short output (3 lines)",    :short, "shell", -> { "build ok\n2 files\ndone" }, {}]
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
  pt = r[:applied] ? "—" : (r[:identical] ? "YES ✅" : "NO ❌")
  md << format("| %s | %s | %s | %d | %d | %.1f%% | %s |\n",
               r[:label], "#{r[:got]} (#{r[:strategy]})", r[:type_ok] ? "✅" : "❌ (#{r[:expected]})",
               r[:full], r[:comp], r[:reduction], pt)
end
all_routed = rows.all? { |r| r[:type_ok] }
pass_identical = rows.reject { |r| r[:applied] }.all? { |r| r[:identical] }
md << "\nRouting: #{all_routed ? "every fixture routed to the expected strategy. ✅" : "MISROUTE — see table. ❌"}\n"
md << "Passthrough fidelity: #{pass_identical ? "every passthrough output is byte-identical to its input. ✅" : "BROKEN — see table. ❌"}\n"

out = File.join(__dir__, "results", "router_per_type.md")
File.write(out, md)
puts "\nwrote #{out}"
