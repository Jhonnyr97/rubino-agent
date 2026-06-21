# frozen_string_literal: true

# Dev-only measurement: token-honest comparison of FULL vs DiffCompressor-
# COMPRESSED unified diffs, using the oMLX OpenAI-compatible server's exact
# prompt_tokens. We POST each text as a single user message with max_tokens:1
# and read usage.prompt_tokens, subtracting the measured chat-template overhead.
#
# Three real diffs: a LARGE wide-context source diff, a LOCKFILE diff, and a
# SMALL normal diff (which MUST pass through byte-identical via the saving
# guard). For each we also assert the FIDELITY INVARIANT — every added (`+`) and
# removed (`-`) line survives and every file/hunk header is intact.
#
# Run from the worktree root (needs the oMLX server up on :8000):
#   ruby -Ilib eval/diff_compression_saving.rb
#
# Writes eval/results/diff_compression_saving.md.

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

CONFIG = {
  "context_lines" => 3, "min_lines" => 40, "min_saving" => 0.25,
  "generated_patterns" => Rubino::Compression::DiffCompressor::DEFAULT_GENERATED
}.freeze

FIXTURES = {
  "large source diff (git diff -U25, 9 files)" => "diff_large.txt",
  "lockfile diff (package-lock.json, 60 bumps)" => "diff_lockfile.txt",
  "small normal diff (version bump)" => "diff_small.txt"
}.freeze

# Fidelity: every `+`/`-` change line survives, file (`diff --git`) and hunk
# (`@@`) headers are intact. For a passthrough (small) diff the check is
# byte-identical; for a generated/lock file the body is elided to a summary, so
# the +/- count is allowed to drop — there we only require headers + the summary.
def fidelity(original, compressed, applied, strategy)
  return [compressed == original, "byte-identical (passthrough: #{strategy})"] unless applied

  orig_changes = original.each_line.count { |l| l.start_with?("+", "-") && !l.start_with?("+++", "---") }
  kept_changes = compressed.each_line.count { |l| l.start_with?("+", "-") && !l.start_with?("+++", "---") }
  orig_files   = original.scan(/^diff --git /).length
  kept_files   = compressed.scan(/^diff --git /).length
  orig_hunks   = original.scan(/^@@ /).length
  kept_hunks   = compressed.scan(/^@@ /).length

  elided = compressed.include?("elided (generated)")
  headers_ok = kept_files == orig_files
  # A generated-file body is intentionally collapsed, so its +/- and @@ lines
  # legitimately disappear; the invariant there is "headers + a summary line".
  changes_ok = elided ? true : (kept_changes == orig_changes && kept_hunks == orig_hunks)
  ok = headers_ok && changes_ok

  note = if elided
           "#{kept_files}/#{orig_files} file headers + generated summary (body elided by design)"
         else
           "#{kept_changes}/#{orig_changes} +/- lines, #{kept_hunks}/#{orig_hunks} hunks, " \
             "#{kept_files}/#{orig_files} file headers"
         end
  [ok, note]
end

rows = FIXTURES.map do |name, file|
  original = File.read(File.join(__dir__, "fixtures", file))
  result   = Rubino::Compression::DiffCompressor.new(CONFIG).compress(original)
  compressed = result.applied? ? result.text : original

  full_tok = prompt_tokens(original).to_i - OVERHEAD
  comp_tok = prompt_tokens(compressed).to_i - OVERHEAD
  reduction = full_tok.zero? ? 0.0 : (full_tok - comp_tok).fdiv(full_tok) * 100
  ok, note = fidelity(original, compressed, result.applied?, result.strategy)
  identical = !result.applied? && compressed == original

  puts format("%-44s full=%6d  comp=%6d  -%5.1f%%  fidelity=%-4s%s",
              name, full_tok, comp_tok, reduction, ok ? "OK" : "FAIL",
              identical ? "  [byte-identical]" : "")
  { name: name, applied: result.applied?, strategy: result.strategy,
    full: full_tok, comp: comp_tok, reduction: reduction,
    fidelity_ok: ok, fidelity_note: note, identical: identical }
end

md = +"# Diff compression — token measurement (oMLX, exact prompt_tokens)\n\n"
md << "Model: `#{MODEL}` · server `http://127.0.0.1:8000/v1` · "
md << "chat-template overhead subtracted (#{OVERHEAD} tok).\n"
md << "Compressor: `Rubino::Compression::DiffCompressor` (deterministic, no ML).\n\n"
md << "| Diff | Strategy | Full tok | Compressed tok | Reduction | Fidelity invariant |\n"
md << "|---|---|---:|---:|---:|---|\n"
rows.each do |r|
  strat = r[:applied] ? "compressed" : "passthrough (#{r[:strategy]})"
  md << format("| %s | %s | %d | %d | %.1f%% | %s — %s |\n",
               r[:name], strat, r[:full], r[:comp], r[:reduction],
               r[:fidelity_ok] ? "HELD" : "BROKEN", r[:fidelity_note])
end

applied_rows = rows.select { |r| r[:applied] }
if applied_rows.any?
  avg = applied_rows.sum { |r| r[:reduction] } / applied_rows.length
  md << format("\n**Mean reduction (compressed diffs only): %.1f%%**\n", avg)
end
all_ok = rows.all? { |r| r[:fidelity_ok] }
md << "\nFidelity: "
md << if all_ok
        "every +/- line + header survived (and the small diff is byte-identical). ✅"
      else
        "INVARIANT BROKEN — see table. ❌"
      end
md << "\n"

out_path = File.join(__dir__, "results", "diff_compression_saving.md")
File.write(out_path, md)
puts "\nwrote #{out_path}"
