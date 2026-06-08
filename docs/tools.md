# Tools Reference

rubino ships **29 built-in tools** plus support for MCP tools (planned) and custom user-defined tools. Each tool is gated by a `tools.<key>` config flag (opt-out: absent key = enabled, only an explicit `false` disables) and the approval model.

The full list: `read`, `summarize_file`, `write`, `edit`, `multi_edit`, `grep`, `glob`, `git`, `github`, `shell`, `shell_output`, `shell_tail`, `shell_input`, `shell_kill`, `ruby`, `run_tests`, `apply_patch`, `webfetch`, `websearch`, `question`, `todowrite`, `memory`, `session_search`, `attach_file`, `vision`, `skill`, `task`, `task_result`, `task_stop`.

## How tools are gated

- **Config flag** — `tools.<config_key>`. Most tools key on their own name; both `webfetch` and `websearch` share `tools.web`; the file tools and `github` ship no default and are on unless set to `false`. `rubino tools` prints the effective state.
- **Mode** — `plan` mode pares the registry down to read-only tools (no `edit`/`shell`/`git`/…); `default` and `yolo` expose everything (their difference is on the approval path).
- **Approval** — see [security.md](security.md). Shell commands are confirmation-gated by default; a non-bypassable hardline floor blocks catastrophic commands regardless of mode.
- **Workspace sandbox** — with `tools.workspace_strict: true` (default), write/edit/delete tools are confined to the workspace root (`terminal.cwd` or `Dir.pwd`).

## Built-in Tools

### read

Read a text file from the filesystem with line numbers (cat -n style). Long lines are truncated; the default window is the first chunk of lines.

```
Risk: low
Parameters: file_path, offset, limit
```

### summarize_file

Summarize a large text file WITHOUT loading it into the conversation. The file is map-reduced by a separate summarization model; only the final summary returns, so the raw bytes never enter context. Prefer this over `read` for big documents.

```
Risk: low
Parameters: file_path, focus, max_words
```

### write

Write content to a file, overwriting any existing content. Creates parent directories if needed. Use `edit`/`multi_edit` to modify an existing file in place.

```
Risk: medium
Parameters: file_path, content
```

### edit

Exact string replacement in a file. The old text must match exactly (including whitespace). More precise than full file writes.

```
Risk: medium
Parameters: file_path, old_string, new_string, replace_all
```

### multi_edit

Apply multiple exact string replacements to a single file atomically. Edits apply sequentially; if any edit fails, no changes are written.

```
Risk: medium
Parameters: file_path, edits[], replace_all
```

### grep

Regex content search. Uses ripgrep (rg) if available, falls back to Ruby.

```
Risk: low
Parameters: pattern, path, include, max_results
```

### glob

Find files by glob pattern. Returns paths sorted by modification time.

```
Risk: low
Parameters: pattern, path, max_results
```

### git

Git operations: status, diff, log, branch, show.

```
Risk: low (read-only operations)
Parameters: command, args
```

### github

GitHub integration: PRs, issues, reviews. Uses gh CLI or REST API.

```
Risk: medium
Parameters: action, title, body, number, repo, base, labels
Actions: pr_create, pr_list, pr_view, pr_checks, pr_diff, issue_create, issue_list, issue_view, repo_view, release_list
```

### shell

Execute a shell command. Foreground blocks until exit or `timeout`; pass `run_in_background: true` to fire-and-forget and get a `run_id`.

```
Risk: high (always requires approval unless in allowlist)
Parameters: command, cwd, timeout, run_in_background
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

Send a line of input to the stdin of a running background shell (e.g. answer an interactive prompt) addressed by `run_id`.

```
Risk: medium
Parameters: run_id, input
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

### run_tests

Run the workspace project's test suite and return a **structured** result instead of the raw toolchain firehose. Auto-detects RSpec / Minitest / a Rakefile default task, prefers `bundle exec` when a Gemfile is present (falls back to the bare runner if the bundle is broken), and returns pass/fail counts plus the failing examples (name + file:line + short message) and a short raw tail. Distinguishes "the suite couldn't start" (toolchain error) from "the suite ran and N failed". Use this instead of driving `shell` by hand to run tests. (issue #101)

```
Risk: low
Parameters: path (optional file/pattern), framework (optional: rspec|minitest|rake)
```

### apply_patch

Apply unified diff patches to files.

```
Risk: medium
Parameters: patch, base_path
```

### webfetch

Fetch web page content and return as text.

```
Risk: low
Parameters: url, format (text|html)
```

### websearch

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

### todowrite

Track tasks during a session.

```
Risk: low
Parameters: todos[] (content, status, priority)
```

### memory

Persist facts across sessions. `action=add` records a new fact, `replace` updates an existing one, `remove` deletes one. `target=user` writes the user profile; `target=memory` writes general memory. Content is scanned for prompt-injection / exfiltration patterns and subject to a character budget.

```
Risk: medium
Parameters: action, target, content, old_text
```

### session_search

Full-text search across past session messages. Returns matched messages with highlighted snippets and the owning session id.

```
Risk: low
Parameters: query, since, until, role, tool, limit
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

Load a skill body (Level 2) and any bundled files (Level 3) on demand, or create a new skill (`action: "create"`). The agent sees available skills (name + description) up front and calls this to pull in the full instructions only when relevant. After a complex, repeatable task it can also distil what it did into a new skill — and the deterministic post-turn `DistillSkillJob` does this automatically. Gated by `tools.skill`. See **[docs/skills.md](skills.md)** for the skill system — the 3-level disclosure, creating skills (the post-turn job + the on-demand tool), authoring `SKILL.md` files, and the `SKILL_LOADED` / `SKILL_CREATED` observability signals.

```
Risk: low
Parameters: action, name, file_path, description, body
```

### task

Delegate a sub-task to an isolated subagent run (default: a background subagent). Gated by `tools.task`. Subagents never receive the `task` tool themselves, so they can't spawn further subagents (no nesting).

```
Risk: medium
Parameters: agent, prompt, (background)
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
