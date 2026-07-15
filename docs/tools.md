# Tools Reference

rubino ships **25 built-in tools** plus dynamic MCP tools (started at boot when `mcp.servers` is configured — see [mcp.md](mcp.md); being server-dependent they are excluded from the drift-checked list below) and custom user-defined tools. Each tool is gated by a `tools.<key>` config flag (opt-out: absent key = enabled, only an explicit `false` disables) and the approval model. The count and list below are drift-checked against the live registry by `spec/docs/tools_doc_drift_spec.rb`.

The full list (registration order): `read`, `write`, `edit`, `grep`, `glob`, `shell`, `shell_output`, `shell_tail`, `shell_input`, `shell_kill`, `ruby`, `web_fetch`, `web_search`, `question`, `todowrite`, `memory`, `session_search`, `attach_file`, `vision`, `skill`, `task`, `task_result`, `task_stop`, `steer`, `probe`.

Several tools share one config gate, so `rubino tools` shows **20 rows** (config groups), not 25: `web_fetch` + `web_search` share `tools.web`, and the whole delegation family (`task`, `task_result`, `task_stop`, `steer`, `probe`) rides on `tools.task` — disabling delegation disables them all.

## How tools are gated

- **Config flag** — `tools.<config_key>`. Most tools key on their own name; `web_fetch`/`web_search` share `tools.web`; the delegation family shares `tools.task`; absent keys default to enabled. `rubino tools` prints the effective state per config group.
- **Mode** — `plan` mode pares the registry down to read-only tools (no `edit`/`shell`/`git`/…); `default` and `yolo` expose everything (their difference is on the approval path).
- **Approval** — see [security.md](security.md). Shell commands are confirmation-gated by default; a non-bypassable hardline floor blocks catastrophic commands regardless of mode.
- **Workspace sandbox** — with `tools.workspace_strict: true` (default), write/edit/delete tools are confined to the workspace root (`terminal.cwd` or `Dir.pwd`).

## Output compression

When `tool_output_compression.enabled` is on (off by default; `rubino setup`
offers it), every tool's output passes through a deterministic content router
before it reaches the model: test/build/lint **logs** are reduced to their
failures + summary, a **whole-file source read** can come back as a skeleton, and
**diffs / grep results / JSON / short output pass through byte-identical**. The
full original is always recoverable: the compressed view ends with a passive
pointer carrying an `id` (`retrieve_output id=…`), and the model recovers the
verbatim original by calling the `retrieve_output` tool with that id — there is
**no cat-able filesystem path** in the pointer, so a small model can't `sed`/
`grep`/`cat` a spill path and re-inflate the very output compression just shrank.
While enabled, `read` and `shell` advertise an extra `compress` boolean parameter
(default `true`) so the model can pass `compress:false` to get one call's output
verbatim, and the registry adds the `retrieve_output` recovery tool (present
**only** while compression is enabled — it is absent from the default registry,
so the count below is unchanged). See
[configuration.md](configuration.md#tool_output_compression) for the full key
reference. Compression is OFF in the default registry, so the parameter lists
below describe the shipped (uncompressed) behaviour.

## Built-in Tools

### read

The unified reader. A **text/code file** is returned with line numbers (cat -n style); `offset`/`limit` page through it and long lines are truncated. A **rich document** (PDF, DOCX, XLSX, PPTX, HTML, CSV, JSON, XML) is auto-detected and converted to Markdown **in-process** (no external `markitdown`/`pdftotext`), then returned framed as untrusted user data (nonce-delimited, defanged) — folding in the former standalone `read_attachment` tool.

The document route is driven by the **detected file kind** (fail-closed classification: regular-file check, workspace confine, size cap, magic-bytes-wins MIME) plus the dedicated-converter set, so a text file merely *named* `report.docx` still reads as text while converted-document bytes never ride read's trusted output/`:code`-redaction path (a converted document escalates to the full `:shell` redaction). `offset`/`limit`/`compress` apply to text files only. A document too large to inline is spilled to a file you then page with `read`/`grep`; if a format has no in-process converter (its optional gem isn't installed) an actionable shell-extraction hint is returned instead of raising. Conversion is provided by the in-repo `Rubino::Documents` module, whose CORE converters lean on optional MIT gems (`roo`, `docx`, `pdf-reader`, `ruby_powerpoint`) that are lazily required — none is a hard dependency, and `rubino doctor` reports which formats are available in-process.

```
Risk: low
Parameters: file_path, offset, limit, compress
```

### write

Write content to a file, overwriting any existing content. Creates parent directories if needed. Use `edit` to modify an existing file in place.

```
Risk: medium
Parameters: file_path, content
```

### edit

Exact string replacement in a file. The old text must match exactly (including whitespace). More precise than full file writes.

For a **single** replacement, pass `old_string`/`new_string` (and `replace_all` to replace every occurrence). For **multiple** replacements in one file, pass an `edits` array instead: the edits apply atomically (all-or-nothing) and sequentially (each later edit sees the result of earlier ones); if any edit fails, no changes are written. Use `old_string`/`new_string` **or** `edits`, not both.

```
Risk: medium
Parameters: file_path, old_string, new_string, replace_all,
            edits[] (each with old_string, new_string, replace_all)
```

### grep

Regex content search. Uses ripgrep (rg) if available, falls back to Ruby.

```
Risk: low
Parameters: pattern, path, include, max_results, before, after, context
```

### glob

Find files by glob pattern. Returns paths sorted by modification time.

```
Risk: low
Parameters: pattern, path, max_results, include_ignored
```

### shell

Execute a shell command. Foreground blocks until exit or `timeout`; pass `run_in_background: true` to fire-and-forget and get a `run_id`.

Commands run under `bash -o pipefail` (foreground and background), so a failure in the **middle** of a pipeline surfaces as the pipeline's exit code instead of being masked by an innocuous last stage. One consequence: an early-closing consumer (`cmd | head -1`) makes the upstream stage exit 141 (128+SIGPIPE); the tool reports the honest exit code with a SIGPIPE note but treats it as success.

Provably read-only commands (`ls`, `grep`, `git log`, ...) run without an approval prompt by default — see [Auto-allowed read-only commands](security.md#auto-allowed-read-only-commands).

When a write fails because the OS write-jail blocked a path **outside** the workspace, re-run with `disable_sandbox: true` to run the command outside the jail after an explicit approval (foreground only; gated by `tools.sandbox.escalation`, see [OS write-jail](security.md#os-write-jail)). `~/.rubino` skills are managed with the `skill` tool instead.

```
Risk: high (always requires approval unless in allowlist or provably read-only)
Parameters: command, cwd, timeout, run_in_background, disable_sandbox, compress
```

### shell_output

Read output from a background shell started via `shell` with `run_in_background: true`. Returns only new bytes by default; pass `mode: "all"` for the full buffer.

```
Risk: low
Parameters: run_id, mode
```

### shell_tail

Follow a background shell — block until new bytes arrive on its `run_id`, the process exits, or `timeout` elapses. Use for `tail -F`-style following.

```
Risk: low
Parameters: run_id, timeout
```

### shell_input

Send input to a background shell's stdin — answer an interactive prompt (Y/N, menu selection, password) of a running command. A newline is appended by default (like pressing Enter); pass `enter: false` for raw bytes, or `eof: true` to close stdin (EOF).

```
Risk: medium
Parameters: run_id, text, enter, eof
```

### shell_kill

Terminate a background shell started via `shell`. Sends SIGTERM to the process group, then SIGKILL if still alive.

```
Risk: medium
Parameters: run_id
```

### ruby

Evaluate Ruby code and return the result. The snippet runs in a **separate Ruby process rooted at the workspace**, with the project's `lib/` and the workspace root prepended to `$LOAD_PATH` (like `ruby -Ilib -I. -e ...`) — so `require 'my_project/file'` and relative requires of the code being worked on resolve. A child process also keeps the snippet from crashing or polluting the host agent (it can `exit`, redefine constants, leak globals). (issue #102)

```
Risk: medium
Parameters: code
```

### web_fetch

Fetch content from a URL and return it as text. Useful for reading documentation, API references, and web pages. Convertible documents (PDF, DOCX, XLSX, PPTX) are fetched, spilled to disk, and converted to Markdown in-process via `Rubino::Documents` (the same engine the `read` tool uses for documents); opaque binaries (images, audio, video, archives) are still refused.

```
Risk: low
Parameters: url, format (text|html), method (get|head)
```

`format: "text"` (default) runs a readability-style **main-content extraction**
(nokogiri): page chrome — `script`, `style`, `noscript`, `nav`, `header`,
`footer`, `aside`, `form`, `svg`, `iframe`, `button`, plus ARIA landmark roles
(`navigation`, `banner`, `contentinfo`, `search`, `complementary`) — is dropped,
the main container is preferred (`<main>` → `[role=main]` → `<article>` →
`<body>`), and the kept subtree is serialized to markdown-ish text (`## `
headings, `- ` list items, blank-line-separated paragraphs, entities decoded).
This strips nav menus/footers/cookie banners and typically cuts tokens
substantially on article and docs pages.

Two guarantees so capability is never lost:

- **Safety fallback** — if the extracted text is under ~30% of the full page
  text (or below a small char floor), the tool returns the full-page strip
  instead, so a page whose content isn't in a clean `<main>`/`<article>` is never
  over-trimmed. Malformed HTML that nokogiri can't parse also falls back (a fetch
  never crashes). When extraction trims a lot, a one-line note points back at the
  raw escape hatch.
- **Raw escape hatch** — `format: "html"` returns the full raw HTML **verbatim**,
  completely unprocessed, for when the model wants the original page.

#### Document conversion

When the response Content-Type is a convertible office format, `web_fetch` spills the raw bytes to disk and converts them to Markdown in-process:

| Format | Content-Type | Optional gem |
|---|---|---|
| PDF | `application/pdf` | `pdf-reader` |
| DOCX | `application/vnd.openxmlformats-officedocument.wordprocessingml.document` | `docx` |
| XLSX | `application/vnd.openxmlformats-officedocument.spreadsheetml.sheet` | `roo` |
| PPTX | `application/vnd.openxmlformats-officedocument.presentationml.presentation` | `ruby_powerpoint` |

The converted Markdown is framed as untrusted user data (same nonce-delimited preamble the `read` tool uses for documents). When a format's optional gem isn't installed, the tool returns an actionable hint telling the user to run `rubino setup` (which interactively offers to install `pdf-reader`) or `gem install <name>`. `rubino doctor` reports which document formats are available in-process and names the exact gem for each missing one.

Large converted documents (over the inline text budget, ~100 KB) are written to a temp file with a pointer to read/search them with `read`/`grep`. Documents that exceed the 20 MB conversion cap are refused with a hint to narrow them first.

#### HEAD requests

`method: "head"` runs a HEAD request through the same SSRF-safe path as GET: the URL is validated against the SSRF guard, the connection is IP-pinned, and redirects are followed (up to 5 hops). No body is fetched. Returns a compact status line:

```
HEAD https://example.com -> 200 OK | Content-Type: text/html | Content-Length: 1234
```

Use HEAD for lightweight link-checking or to inspect Content-Type / Content-Length without downloading the resource.

### web_search

Search the web. Supports Tavily (best), SearXNG, or DuckDuckGo fallback.

```
Risk: low
Parameters: query, max_results
Env: TAVILY_API_KEY or SEARXNG_URL (optional)
```

### question

Ask the user a question with optional predefined choices.

```
Risk: low
Parameters: question, options[], multiple
```

Non-interactive / no-TTY behavior: the tool fails closed. When there is no
interactive terminal to prompt on — a piped or redirected `rubino prompt`
(stdin or stdout not a TTY), a subagent context, or an API/server run with no
pending clarify gate — nothing is prompted and no terminal escape sequences
are emitted. The tool immediately returns a deterministic structured result
("No answer: no interactive user input available …") instructing the model
not to assume a choice on the user's behalf. It never reads ambient stdin and
never silently auto-selects an option. On the HTTP API path with a clarify
gate wired, the question is still delivered as a `clarify.required` event and
the tool waits for the client's answer as before.

### todowrite

Track tasks during a session.

```
Risk: low
Parameters: todos[] (content, status, priority)
```

### memory

Persist facts across sessions. `action=add` records a new fact, `replace` updates an existing one, `remove` deletes one. `target=user` writes the user profile; `target=memory` writes general memory. Content is scanned for prompt-injection / exfiltration patterns and subject to a character budget.

```
Risk: low
Parameters: action, target, content, old_text
```

### session_search

Full-text search across past session messages. Returns matched messages with highlighted snippets and the owning session id.

```
Risk: low
Parameters: query, since, before, role, tool, limit
```

### attach_file

Attach a previously-written file to the current turn as a downloadable artifact for the user. Call AFTER creating the file with `write`/`edit`/`shell`. Does not copy or move the file — only registers it as a deliverable.

```
Risk: low
Parameters: file_path, filename
```

### vision

Ask a multimodal model to describe or interpret an image (charts, screenshots, diagrams, photos). Provide an optional focused question. Hidden only when no auxiliary vision model is configured and the primary model cannot see.

```
Risk: low
Parameters: file_path, question
```

### skill

Load a skill body (Level 2) and any bundled files (Level 3) on demand, or author/maintain skills: `action: "create"` (new), `"edit"`/`"patch"`/`"write_file"` (update a home-authored skill), `"delete"` (remove one). The agent sees available skills (name + description) up front and calls this to pull in the full instructions only when relevant. After a complex, repeatable task it can also distil what it did into a new skill. The write actions are approval-gated and confined to the home skills dir (bundled skills are protected); they run in-process, so deleting a skill works where a shell `rm` under the OS write-jail cannot. Gated by `tools.skill`. See **[docs/skills.md](skills.md)** for the skill system — the 3-level disclosure, creating skills (the post-turn job + the on-demand tool), authoring `SKILL.md` files, and the `SKILL_LOADED` / `SKILL_CREATED` observability signals.

```
Risk: low
Parameters: action, name, file_path, description, body, old_str, new_str, content
```

### task

Delegate a sub-task to an isolated subagent run (default: a background subagent that returns a task id immediately; `background: false` runs it inline). Gated by `tools.task`. Subagents keep the `task` tool, so they CAN spawn their own subagents — scoped nesting, bounded by three caps enforced in one place (`BackgroundTasks#reserve`): `tasks.max_depth` (default 2), `tasks.max_children_per_node` (default 3), and `tasks.max_concurrent_total` (default 8). See [agents.md](agents.md).

```
Risk: low (the nested run's tools carry their own approval/risk gates)
Parameters: subagent, prompt, background (boolean, optional; default false)
```

### task_result

Poll a background subagent for its output (companion to `task`, mirrors `shell_output`). Gated by `tools.task`.

```
Risk: low
Parameters: task_id
```

### task_stop

Stop a running background subagent (companion to `task`, mirrors `shell_kill`). Gated by `tools.task`.

```
Risk: medium
Parameters: task_id
```

### steer

Parent→child steering note: park a short note on one of YOUR OWN running subagents; it is folded into the child's context at its next turn boundary and persists (it changes the child's trajectory). Ownership-scoped at call time — only your direct children. The model counterpart of the human `/agents <id> steer "…"`. Gated by `tools.task`.

```
Risk: low
Parameters: task_id, note
```

### probe

Parent→child ephemeral peek: check on one of YOUR OWN running subagents without disturbing it (read-only — nothing is saved to the child). `live: false` (default) returns a free registry snapshot (status, tool count, last activity, recent lines); `live: true` runs a billed one-shot model peek over the child's transcript, budgeted per child (`tasks.max_live_probes_per_child`, default 5). The model counterpart of the human `/agents <id> probe "…"`. Gated by `tools.task`.

```
Risk: low
Parameters: task_id, question, live
```

---

## MCP Tools

Tools from connected MCP servers are automatically registered with a prefix:

```
server_name_tool_name
```

Configure MCP servers in `config.yml`:

```yaml
mcp:
  servers:
    myserver:
      transport: stdio
      command: "npx"
      args: ["my-mcp-server"]
```

---

## Custom Tools

Create Ruby files in `.rubino/tools/`:

```ruby
# .rubino/tools/deploy.rb
Rubino.define_tool do
  name "deploy"
  description "Deploy the application to staging or production"

  input_schema({
    type: "object",
    properties: {
      environment: { type: "string", enum: ["staging", "production"] }
    },
    required: ["environment"]
  })

  risk_level :high

  execute do |args|
    env = args["environment"]
    `./deploy.sh #{env} 2>&1`
  end
end
```

Custom tools:
- Are automatically discovered and registered
- Can override built-in tools by name
- Support all risk levels and approval flows
- Can execute any system command or Ruby code

---
## Inline Tool Card (`live_card`)

A tool can opt into the multiplexer dropdown **while it runs** by declaring a `live_card`
lambda in its class:

```ruby
class MyBuildTool < Tools::Base
  live_card ->(args) { "🔨 build #{args[:target]}" }

  # … rest of tool definition
end
```

The lambda receives the tool's arguments hash and returns a header string shown as the
dropdown-row label. Fast/quiet tools declare nothing — the default is to **not** appear in
the dropdown (opt-in).

**While the tool runs**, the user sees its entry in the multiplexer:

- **↑↓** navigates to it, **⏎** clears the timeline and shows the tool's streaming output
  there
- **←** returns to the main timeline

An inline tool **blocks** the agent thread (it runs synchronously) — the card is the live
window on that blocking operation, exactly like a background shell or subagent. The adapter
is torn down automatically when the tool completes or fails.

## Background Crash-Safe Logging

When a background subagent or shell runs, rubino writes its transcript to a per-task log
file that survives a process crash (sync-flushed on every write):

| Entry type | Log path |
|---|---|
| Subagent (`task`) | `<workspace>/.rubino/sessions/<session_id>/tasks/<sa_id>.jsonl` |
| Background shell | `<workspace>/.rubino/logs/bg/<bg_id>.log` |

- The **subagent log** is a JSONL file — one JSON object per line (Append-only, flushed
  immediately). It records every turn: user messages, assistant blocks (text + tool use),
  tool results, and a terminal `result` event. Mirrors Claude Code's task log format.
- The **background shell log** is a plain file capturing stdout+stderr, opened with
  `sync = true` so every write hits the disk. The log path is in the shell handle, so
  the user can `tail -f` it from another terminal.

Both paths live under the workspace root (not `~/.rubino`) so the OS write-jail permits
them — the agent process always has write access to its own workspace session/log dirs.

## Approval-Preview via ToolPresentation

Each tool can customize its approval-prompt display by overriding
`ToolPresentation#preview_arguments` in its presentation subclass:

```ruby
class ToolPresentation < Tools::ToolPresentation
  def preview_arguments(label, arguments)
    # build and return a formatted string (diff preview, content snippet, …)
    # return nil to fall back to the executor's generic key-value formatter
  end
end
```

Receives the display label (e.g. `"edit"`, `"echo (mcp:chaos)"`) and the raw arguments
hash. Returns a complete formatted string for the approval prompt, or `nil` to use the
default. The `edit` tool ships with a preview that shows the diff/file
content inline at the approval prompt.

When a tool does **not** provide a custom preview, the generic key-value formatter
applies these truncation rules (hardcoded, not configurable):

| Rule | Behaviour |
|---|---|
| Single arg, single line, ≤120 chars | Inlined: `tool wants to run: <value>` |
| Single arg, single line, >120 chars | Truncated to 117 chars + `…` |
| Multi-line value | First **5 lines** shown; rest counted as `[… N more line(s)]` |
| Secret values | Credential-like values (API keys, tokens) are **masked** before display |

The number of visible key-value pairs is NOT capped — a tool with many parameters shows
all of them (subject to the per-value truncation above).
