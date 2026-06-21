# frozen_string_literal: true

# Dev-only measurement: token-honest comparison of FULL vs LogCompressor-
# COMPRESSED command output, using the oMLX OpenAI-compatible server's exact
# prompt_tokens. We POST each text as a single user message with max_tokens:1
# and read usage.prompt_tokens, subtracting the measured chat-template overhead.
#
# Run from the worktree root (needs the oMLX server up on :8000):
#   ruby -Ilib eval/log_compression_saving.rb
#
# Writes eval/results/log_compression_saving.md.

require "json"
require "net/http"
require "uri"
require "rubino"

BASE   = "http://127.0.0.1:8000/v1/chat/completions"
APIKEY = "fake" # the literal configured api_key on the local oMLX server
MODEL  = "Qwen3.6-35B-A3B-MLX-8bit"

# --- exact token count via the prompt_tokens trick ---------------------------
def prompt_tokens(text)
  uri = URI(BASE)
  http = Net::HTTP.new(uri.host, uri.port)
  http.read_timeout = 120
  req = Net::HTTP::Post.new(uri)
  req["Authorization"] = "Bearer #{APIKEY}"
  req["Content-Type"]  = "application/json"
  req.body = JSON.generate(
    model: MODEL,
    messages: [{ role: "user", content: text }],
    max_tokens: 1
  )
  res = http.request(req)
  JSON.parse(res.body).dig("usage", "prompt_tokens")
end

# Measure the chat-template overhead ONCE (empty user message) so we report the
# tokens of the CONTENT, not the wrapper.
OVERHEAD = prompt_tokens("").to_i
puts "chat-template overhead: #{OVERHEAD} tokens"

CONFIG = {
  "min_lines" => 40, "max_total_lines" => 100, "max_errors" => 10,
  "max_warnings" => 5, "max_stack_traces" => 3, "context_lines" => 4
}.freeze

FIXTURES = {
  "rspec (full suite, 21 failures)" => "rspec_full.txt",
  "rubocop (750 files, 20 offenses)" => "rubocop_full.txt",
  "git log --oneline -50" => "git_log.txt",
  "git log --stat -15" => "git_log_stat.txt",
  "ls -R lib" => "ls_recursive.txt"
}.freeze

# Heuristic failure/summary descriptors per fixture, to assert the fidelity
# invariant held (every failure + the tally survived). For non-test outputs the
# invariant is vacuous (no failures), reported as n/a.
def fidelity(name, original, compressed)
  case name
  when /rspec/
    failures = original.scan(/^\s*(\d+)\) /).flatten.map(&:to_i).uniq
    kept = compressed.scan(/^\s*(\d+)\) /).flatten.map(&:to_i).uniq
    summary = original[/\d+ examples?, \d+ failures?[^\n]*/]
    missing = failures - kept
    ok = missing.empty? && (summary.nil? || compressed.include?(summary))
    [ok, "#{kept.length}/#{failures.length} failure descriptors + tally#{" (MISSING #{missing.inspect})" unless ok}"]
  when /rubocop/
    offenses = original.scan(/^\S+:\d+:\d+: [A-Z]:/).length
    kept = compressed.scan(/^\S+:\d+:\d+: [A-Z]:/).length
    summary = original[/\d+ files? inspected[^\n]*/]
    ok = kept == offenses && (summary.nil? || compressed.include?(summary))
    [ok, "#{kept}/#{offenses} offenses + summary"]
  else
    [true, "n/a (no failures)"]
  end
end

rows = FIXTURES.map do |name, file|
  original = File.read(File.join(__dir__, "fixtures", file))
  result   = Rubino::Compression::LogCompressor.new(CONFIG).compress(original)
  compressed = result.applied? ? result.text : original

  full_tok = prompt_tokens(original).to_i - OVERHEAD
  comp_tok = prompt_tokens(compressed).to_i - OVERHEAD
  reduction = full_tok.zero? ? 0.0 : (full_tok - comp_tok).fdiv(full_tok) * 100
  ok, note = fidelity(name, original, compressed)

  puts format("%-34s full=%6d  comp=%6d  -%.1f%%  fidelity=%s",
              name, full_tok, comp_tok, reduction, ok ? "OK" : "FAIL")
  { name: name, applied: result.applied?, full: full_tok, comp: comp_tok,
    reduction: reduction, fidelity_ok: ok, fidelity_note: note,
    strategy: result.strategy }
end

# --- write the report --------------------------------------------------------
md = +"# Log compression — token measurement (oMLX, exact prompt_tokens)\n\n"
md << "Model: `#{MODEL}` · server `http://127.0.0.1:8000/v1` · "
md << "chat-template overhead subtracted (#{OVERHEAD} tok).\n"
md << "Compressor: `Rubino::Compression::LogCompressor` (deterministic, no ML).\n\n"
md << "| Output | Full tok | Compressed tok | Reduction | Fidelity invariant |\n"
md << "|---|---:|---:|---:|---|\n"
rows.each do |r|
  applied = r[:applied] ? "" : " (passthrough: #{r[:strategy]})"
  md << format("| %s%s | %d | %d | %.1f%% | %s — %s |\n",
               r[:name], applied, r[:full], r[:comp], r[:reduction],
               r[:fidelity_ok] ? "HELD" : "BROKEN", r[:fidelity_note])
end

applied_rows = rows.select { |r| r[:applied] }
if applied_rows.any?
  avg = applied_rows.sum { |r| r[:reduction] } / applied_rows.length
  md << format("\n**Mean reduction (compressed outputs only): %.1f%%**\n", avg)
end
all_ok = rows.all? { |r| r[:fidelity_ok] }
md << "\nFidelity: "
md << (all_ok ? "every failure descriptor + summary survived in every output. ✅" : "INVARIANT BROKEN — see table. ❌")
md << "\n"

out_path = File.join(__dir__, "results", "log_compression_saving.md")
File.write(out_path, md)
puts "\nwrote #{out_path}"
