# Security

rubino runs real tools — shell, file writes, Ruby, git. The safety model is layered: a non-bypassable hardline floor, explicit permission rules, an approval gate, a shell-confirmation policy, and a workspace sandbox. When run inside an isolated VM, the blast radius is limited to that VM.

## Is it safe to enable shell?

Yes. `tools.shell` is **on by default** because the agent ships to run inside an isolated VM where running commands is the whole point. Every command is still gated: by default `security.confirm_policy` is `dangerous_only`, so a command matching a dangerous pattern goes through an approval prompt (set it to `confirm_all` to prompt on every command), and a hardline floor blocks catastrophic commands regardless of any setting.

## The approval decision order

`Security::ApprovalPolicy#decide` resolves every tool call in this fixed order. The key invariant: **deny-class checks run before every allow path** — neither the hardline floor nor an explicit `permissions: deny` can be overridden by `yolo`, a `permissions: allow` rule, or the command allowlist.

1. **Hardline floor** (`:deny`) — a floor *below* yolo. Catastrophic, unrecoverable commands are denied unconditionally.
2. **`permissions: deny`** — an explicit deny rule also beats yolo.
3. **yolo / skip-approvals** — the runtime `--yolo` flag (`Modes.skip_approvals?`, not the config `approvals.mode: "skip"` value — see step 9) — allow-exit (the doom-loop guard still applies).
4. **Doom-loop guard** — breaks an autopilot stuck repeating the same call.
4b. **Escalation request** (`shell disable_sandbox: true`) — always `:ask`, with a fresh, distinct approval (see [Escalation](#escalation-disable_sandbox) below), even for an otherwise pre-approved command. Below yolo (step 3), above every remaining allow/ask path (steps 5-9).
5. **`permissions: allow` / `ask`** — remaining explicit rules.
5b. **Secret-file write gate** — writing/editing `.env`, `.ssh`, `.aws`, etc requires explicit approval.
5c. **Secret-file read gate** — reading a credential path with `read`/`grep`/`glob` requires explicit approval: everything under `~/.rubino` (config, memories, session DB) plus the project-local `.env` family anywhere on disk and the `$HOME` credential stores (`~/.ssh`, `~/.aws`, `~/.kube`, `~/.docker`, `~/.gnupg`, `~/.azure`, `~/.config/gh`, `.netrc`, `.git-credentials`). Skill `load` is not gated.
6. **Command allowlist** (prefix match) — pre-approved commands → allow. Then the **read-only auto-allow** at the same seam: a shell command the parser can prove read-only (see [Auto-allowed read-only commands](#auto-allowed-read-only-commands)) → allow.
6c. **Skill write gate** — `skill(action:)` with `"create"` / `"edit"` / `"patch"` / `"write_file"` / `"delete"` requires explicit approval (a background review fork's writes go through a separate trusted path and bypass this gate).
7. **Shell confirm policy** — `confirm_all` → ask; `dangerous_only` → ask only if the command matches a dangerous pattern, else allow.
8a. **Out-of-workspace write widen** — a structured write targeting outside the workspace prompts; approval adds the directory.
8b/8c. **Structured edit / code-exec symmetry** — under `dangerous_only`, in-workspace edits and the `ruby` tool auto-run.
9. **Mode fallback** — `approvals.mode: "auto"` asks only for high-risk tools, else allows; `"manual"` **and** `"skip"` both ask for any risky (write/edit/shell) tool, else allow. Config `"skip"` is deliberately **not** a full allow-exit like runtime `--yolo` (step 3) — it exists so headless runs still hit the [fail-closed floor](#headless--non-interactive-approvals-fail-closed) for risky actions instead of silently auto-running them.

## The hardline floor

A deliberately **tiny** unconditional blocklist of commands with no recovery path — they never run via the agent, no matter the mode or rules:

- recursive delete of `/`, a protected system directory (`/etc`, `/usr`, …), or the home directory (`~` / `$HOME`)
- filesystem format (`mkfs`)
- `dd` to / redirect into a raw block device (`/dev/sda`, …)
- recursive `chmod`/`chown` of the root filesystem
- fork bomb
- kill all processes (`kill -1`)
- system shutdown / reboot / halt / poweroff (incl. `init 0/6`, `systemctl poweroff`, `telinit`)
- `sudo -S` (password guessing via stdin) — unless `SUDO_PASSWORD` is set

Recoverable-but-risky operations (`git reset --hard`, `rm -rf /tmp/x`, `chmod -R 777`, `curl | sh`) are **not** here — they belong to the dangerous-pattern layer, where yolo/approval can pass them through. The same hardline check runs again as defense-in-depth inside `ShellTool` before execution.

## Permission rules

Pattern rules in `config.yml` (wildcard support) give explicit verdicts:

```yaml
permissions:
  "git *": "allow"
  "shell rm -rf *": "deny"
  "shell bundle *": "allow"
  "write ~/.env": "deny"
  "read *": "allow"
```

Actions: `allow`, `ask`, `deny`. A `deny` rule is a deny-class check and beats every allow path.

## Shell confirmation policy

`security.confirm_policy`:

- **`dangerous_only`** (default) — safe commands run unprompted; only commands matching a dangerous pattern prompt. The hardline floor and `permissions: deny` still run first, so this never weakens the floor.
- **`confirm_all`** — every shell command not otherwise allowed/denied prompts for approval.

(The old `security.require_confirmation_for_shell` key was **removed** — it is no longer honored. Use `security.confirm_policy`.)

## Command allowlist

Prefix-matched commands pre-approved without a prompt:

```yaml
security:
  command_allowlist:
    - "git status"
    - "git diff"
```

An **empty** allowlist pre-approves nothing — pre-approval is opt-in.

A matched entry pre-approves only its **read-only intent**, never a smuggled write/exec form: an allowlisted head can't carry an output/exec flag (`git diff --output FILE`, `sort -o FILE`, `find -exec/-delete`), a git **global** flag (`git -c alias.x='!cmd' x`, `git -c core.sshCommand=…`, `git -C dir`, `--exec-path`), or a mutating/code-loading git subcommand (`git apply`, `git am`, `git push`, hooks). Heads whose argument is itself a program (`awk`, `sed`, `perl`, `python`, `ruby`, `node`, `tar`, `tee`, `xargs`, shells) are **never** auto-approved even if allowlisted — they still prompt. The **shipped default allowlist is empty** (`[]`): read-only commands already run unprompted via the separate read-only auto-allow layer, so nothing needs seeding here. Test/build runners (`bundle exec rspec`, `rake`, `npm test`) are deliberately not auto-approvable because they load and execute arbitrary project code by design — add one explicitly only if you accept that.

> An allowlist is a **convenience** layer, not a security boundary. Per industry practice (Claude Code/Codex, GTFOBins) a deny/allow list of command strings cannot be exhaustive; the OS sandbox is the real floor. This layer is narrowed to close the default-config and bare-`git` RCEs, not to be relied on as the only barrier.

## Auto-allowed read-only commands

A built-in allowlist layer (`Security::ReadonlyCommands`, **on by default**) lets provably read-only shell commands run without a prompt. It is evaluated at the same decision step as the command allowlist — *below* the hardline floor and `permissions: deny`, which always win, even for commands you add yourself.

The built-in set: `ls`, `pwd`, `find`, `cat`, `head`, `tail`, `grep`, `rg`, `wc`, `file`, `stat`, `du`, `df`, `which`, `whoami`, `date`, `tree`, `echo`, plus read-only git subcommands (`git status|log|diff|show|rev-parse|blame`, `git branch` in pure listing form, `git remote`/`git remote -v`).

A command auto-allows only when the **entire line** parses as safe:

- no output redirection (`>`, `>>`, `2>`; `tee` is simply not in the set) — plain `<` input redirection is fine;
- no command substitution (`` ` `` or `$(...)`) or process substitution (`<(...)`, `>(...)`) in a live context (single-quoted text is literal and stays allowed);
- chains (`|`, `&&`, `;`, `||`) only when **every** segment starts with a command from the set — `grep -rn TODO lib | head -20` runs, `cat file; rm file` prompts;
- no wrapper heads smuggling execution (`env`, `xargs`, `sh -c`, `bash -c`, `sudo`, `nohup` are not in the set);
- no leading variable assignments (`FOO=bar ls` prompts — an assignment can change what the command resolves to);
- no mutating flags on otherwise-safe heads: `find -exec/-execdir/-ok/-okdir/-delete/-fprintf/-fprint/-fls`, `date -s/--set`, `tree -o`, `git ... --output`;
- no `&` backgrounding, comments, or unbalanced quotes;
- no dangerous-pattern match on the whole line (defense-in-depth for user-extended sets).

Anything the parser cannot prove safe **fails closed to the normal approval prompt** — never to silent execution.

Configure it under `approvals`:

```yaml
approvals:
  auto_allow_readonly: true   # set false to prompt for everything again
  readonly_commands:          # extend the built-in set; same parse validation applies
    - "jq"                    # bare name matches that command head
    - "docker ps"             # multi-word entry matches those leading tokens
```

## Headless / non-interactive approvals fail closed

A one-shot or scripted run (`rubino prompt`, `chat -q`, or any run with no TTY) has **no interactive session to approve from**, so it **fails closed**: a tool that would otherwise prompt — a write/edit, or a shell command **not** covered by your `permissions` / command allowlist / read-only auto-allow — is **blocked, not run**. A single-line `blocked: <tool> needs approval but no interactive session (use --yolo to allow, or allowlist it)` goes to stderr and the run exits **2**, so automation/CI fails loudly instead of silently skipping (or, worse, auto-executing) the action. Anything you already allowlisted, and every read-only command, still runs unprompted.

To opt back into full auto-execute, pass **`--yolo`**; **`--no-yolo`** forces fail-closed even if a yolo default was set. `--yolo` is honored **only** as a CLI flag — a project-local or persisted config can never grant it, so an untrusted checkout can't silently switch a scripted run into auto-execute. The hardline floor and explicit `permissions: deny` rules still apply under `--yolo`. (See [commands.md §Exit codes](commands.md#exit-codes-scripting-around-prompt--one-shot).)

## Deny/approve scope: once, session, or always

At the approval prompt you can decide for just this call, for the rest of the session, or **always**:

- **Once** — approves this call only; nothing is remembered.
- **Session** — remembered **in-process only** for the rest of the running session (dies with the process; `Run::SessionApprovalCache`), by a **prefix/pattern class**, not the raw command: a **dangerous** command remembers its pattern class (approving `git push --force origin main` once also covers `git push -f other` for the rest of the session), a **plain** command remembers only the exact command (approving `git status` does not auto-approve `git diff`).
- **Always** — the same class/exact-command scoping as Session, but also written to **disk**: an approve persists a rule to `security.command_allowlist` (`Security::AllowlistPersister`), a "deny always" persists a `permissions: <pattern>: "deny"` rule (`Security::DenyPersister`, which `ApprovalPolicy#decide` checks first — step 2 above). Both survive a process restart and take effect in the live config immediately, no reload needed. The menu offers a broad **prefix** class when one is derivable from a non-dangerous command (e.g. "`git *` commands"), or the narrow/exact command otherwise.

The granularity matches the matcher, so approving `shell ls` never auto-approves `shell rm -rf /`.

## Abandoned approvals

A run parked on a human decision is bounded by `approvals.wait_timeout_seconds` (default 900s / 15 min). On expiry the gate **auto-denies** (never auto-approves) and frees the worker thread, so a closed tab can't park a server worker indefinitely. While a decision is pending, the SSE idle watchdog is suspended for that run so it isn't reaped mid-wait. Set to `null` for an unbounded wait (interruptible only by an explicit run stop — discouraged on shared servers).

## Workspace sandbox

`tools.workspace_strict: true` (default) confines write/edit/delete tools to the workspace root (`terminal.cwd` or `Dir.pwd`). Set it to `false` only if you trust the model plus the approval flow alone to touch any path the process can reach.

## OS write-jail

Above the tool-level workspace check sits the real floor: an **OS write-jail** (`tools.sandbox`, see [configuration.md](configuration.md#toolssandbox-os-write-jail)) that confines shell and `ruby` **writes** at the kernel level — Seatbelt (macOS) / Landlock (Linux) — to `{workspace roots, $TMPDIR, /tmp, /dev/null}`. Reads stay broad (clone-and-inspect keeps working). The per-command allowlist is a UX convenience; this is the boundary. When no mechanism exists it fails **open** with a one-time banner (or **closed** if `tools.sandbox.require: true`).

`~/.rubino` is **deliberately non-writable** from the jailed shell even though it is the agent's home: it holds the sandbox's own trust anchors (config, `.env`, session DB, the resolved Landlock/Seatbelt helper, skills). Confining the shell out of it closes the self-tamper persistence escape (helper/config poisoning) and loses no legitimate capability — the agent persists all of that from the Ruby **process**, never by spawning the shell. Skills are managed in-process via the `skill` tool (`create`/`edit`/`patch`/`delete`); deleting one with a shell `rm` is refused by the jail by design.

### Escalation (`disable_sandbox`)

When a write-jail denial blocks a legitimate write **outside** the workspace, the model can re-issue the shell call with `disable_sandbox: true` to run it outside the jail — which **always** requires a fresh, explicit approval that discloses it runs outside the jail (model-driven, aligned with Claude Code's `dangerouslyDisableSandbox`). It sits below `--yolo` and below the non-bypassable hardline floor (`rm -rf /` stays denied), and fails closed headless.

`tools.sandbox.escalation` picks the posture: `off` (no hatch — hard-fail), **`protect-home`** (default — an approved escalation runs UNCONFINED on every platform; the approval prompt is the only boundary, `~/.rubino` is NOT OS-blocked), or `full` (Codex-style fully-unconfined-on-approval, no OS floor on `~/.rubino`). Both `protect-home` and `full` require explicit human approval; the difference is the disclosure text on the approval card.

## Agent-home read gate

Reading any file under `~/.rubino` (config, memories, session DB) with the `read`, `grep`, or `glob` tools requires **explicit approval** — symmetric with the write gate. This closes the gap where a model could silently inspect rubino's own configuration, memories, or session data. The `skill` tool `load` action reads SKILL.md in-process and is **not** gated (it's the primary skill-loading path).

The same `:ask` gate is deliberately broader than just `~/.rubino` (`Security::SecretPath.read_gated?`): it also covers the project-local `.env` family (`.env`, `.env.local`, `.env.development`, `.env.production`, `.env.test`, `.env.staging`, `.envrc`) **anywhere** on disk, and the `$HOME` credential stores — `~/.ssh` (specifically `id_rsa`, `id_ed25519`, `authorized_keys`, `config`), `~/.aws`, `~/.kube`, `~/.docker`, `~/.gnupg`, `~/.azure`, `~/.config/gh` — plus `.netrc`/`.git-credentials` wherever they sit. An auto-**deny** was deliberately rejected in favor of an auto-**ask** here too: denying outright strands the model with no way to request the exception, and read-before-write would deadlock a legitimate edit (approve `edit .env`, then have the mandatory read refused).

The `shell` tool can still `cat ~/.rubino/*` (or `~/.ssh/id_rsa`, a project `.env`, …) unprompted — this is defense-in-depth, not a security boundary (the shell runs as the same OS user); the value still gets redacted on the way out (see [On-demand document reading](#on-demand-document-reading-the-read-tool) below for the `:shell` vs `:code` redaction profiles).

## Outbound-fetch SSRF guard (`web_fetch` / `web_search`)

Every outbound HTTP(S) request the `web_fetch` and `web_search` tools make — the initial GET/HEAD and each redirect hop — passes through `Rubino::Security::UrlSafety` before it dials out (ported from Hermes' `url_safety.py`). This is a different, stronger mechanism than the attachment guard below: it resolves DNS and checks every answer, not just an allowed-host string.

- **Scheme allowlist** — only `http`/`https`; anything else (`file://`, `data:`, …) is refused.
- **No secrets in the URL** — a URL carrying HTTP userinfo (`user:pass@host`) or a query parameter that looks like a credential (`api_key`, `token`, `password`, `aws_secret_access_key`, …) is refused before any request is made.
- **DNS resolved and every answer checked** — not just the literal hostname: if *any* resolved address is loopback, private (RFC 1918), CGNAT, link-local (including the cloud-metadata range), reserved, multicast, or the IPv6 equivalents (unique-local, `::1`, IPv4-mapped, …), the request is blocked. A literal IP in the URL is checked the same way.
- **Cloud-metadata floor always enforced** — `169.254.169.254`-style IMDS ranges and `metadata.google.internal`/`metadata.goog` are blocked even when private-network fetching is otherwise allowed; nothing legitimate ever needs to reach them.
- **DNS-rebinding safe** — the guard returns the IP(s) it actually validated and the caller pins the connection to that address (TLS SNI/certificate verification still uses the original hostname), so a server can't swap in a private address between the check and the connect.
- **Redirects re-validated per hop** — `web_fetch` never trusts a `Location` header; each redirect target (up to 5 hops, for both GET and HEAD) goes back through the same guard before it's followed.
- **Fails closed** — malformed URLs, DNS failures, and unexpected errors all block the request rather than letting it through.

`web_fetch` defaults to `tools.webfetch.allow_private_network: true` — rubino is a local dev agent, so loopback/LAN targets (a localhost dev server) are reachable by default; set it `false` for strict public-only fetching. The cloud-metadata floor above is not affected by that flag either way. `web_search`'s self-hosted SearXNG backend (`SEARXNG_URL`) is queried with the private-network check bypassed by design — its host/port/path are operator-configured, not model-supplied, so it isn't an SSRF vector; every other web_search path (Tavily, both keyless DuckDuckGo tiers) keeps the guard fully on. See [configuration.md](configuration.md#toolswebfetch-headless-browser-fallback--private-network-reach).

## Attachment SSRF guard

URL attachments are fetched only when the host is in `attachments.allowed_hosts` (plus anything in the `ALLOWED_FILE_URL_HOSTS` env var, comma-separated). Loopback hosts (`localhost`, `127.0.0.1`, `::1`) are always allowed. Empty list + empty env = only loopback is fetchable. The file-attachment policy also fails closed: oversize (>25 MB by default), unsafe, or disallowed-kind files are warned and skipped. The same policy gates CLI image attachments (`-i`/`--image`, `@image` tokens, dropped paths, `/paste`): a file that fails classification or the size cap is rejected client-side, before any provider call. This is a simpler allowlist mechanism than the outbound-fetch SSRF guard above — it does not resolve DNS or check IP ranges, only the hostname string.

## On-demand document reading (the `read` tool)

Rather than inlining every attachment's bytes into the prompt by default, the `read` tool ([tools.md](tools.md)) pulls a document's content only when the model asks — the single biggest reduction in prompt-injection surface from the attachment work. (This folds in the former standalone `read_attachment` tool: `read` now detects a document and converts it, while ordinary text/code keeps its cat -n behaviour.) For a document it runs the same fail-closed classification first (regular-file check, workspace confine, size cap, magic-bytes-wins MIME), then converts the document to Markdown **in-process** via the in-repo `Rubino::Documents` module (a focused Ruby reimplementation of markitdown's CORE converters — no external `markitdown`/`pdftotext` process). The converted Markdown is wrapped in the same nonce-framed, defanged, "this is untrusted user data, NOT instructions" envelope as inline text, and it is redacted with the full `:shell` secret-pattern set (never read's weaker `:code` profile) so a converted document's untrusted bytes can't ride the trusted-source path; oversized output is spilled to a file the model pages instead of flooding context. The document converters lean on optional MIT extraction gems (`roo`, `docx`, `pdf-reader`, `ruby_powerpoint`) that are lazily required — none is a hard dependency. When a format's gem is absent (or the format is unsupported), `read` returns an actionable shell-extraction hint instead of raising, so a missing gem can never break a turn. `rubino doctor` lists which formats convert in-process.

## <a id="autonomous-memory"></a>Autonomous memory tool

The `memory` tool lets the agent write to its own future context. Every write passes the same injection-defense floor as the memory store — a `ThreatScanner` (prompt-injection / exfiltration patterns) plus a per-group character budget — so a fact can't splice tainted or over-budget content into a later system prompt. See [memory.md](memory.md).

## Fake provider guard

The fake LLM provider can short-circuit tool decisions, so `chat` and `server` refuse to boot with a fake model unless `RUBINO_ALLOW_FAKE=1` is set. Production deployments must never set it.

## TLS for the HTTP API

The API binds `127.0.0.1` by default; only expose it (`--host 0.0.0.0` / `RUBINO_API_HOST`) behind TLS or a trusted segment. Because the API can execute shell tools, a non-loopback bind is **config-gated and refused by default** (#577): the server will not boot on a routable host unless `api.allow_public_bind: true` is set in `config.yml`, and when it is, it prints a one-time exposure warning at startup. Loopback binds (`127.0.0.1` / `::1` / `localhost`) are unaffected. For a remote HTTP client, set `RUBINO_TLS=1` (or leave a cert in place) and the API serves over a self-signed cert that the client **pins** (no DNS / Let's Encrypt needed). On first boot it generates `cert.pem` + `key.pem` under `$RUBINO_HOME/tls` (CN/SAN = host/IP, ~10y) and reuses them. Hand the public cert to a pinning client with:

```bash
rubino tls-cert   # prints $RUBINO_HOME/tls/cert.pem (generating it if absent)
```

The private key never leaves the box. (refs #69)

Set `RUBINO_ENCRYPTION_KEY` to encrypt stored OAuth tokens at rest (required for the OAuth routes). See [oauth-providers.md](oauth-providers.md).
