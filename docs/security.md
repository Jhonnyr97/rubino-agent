# Security

rubino runs real tools — shell, file writes, Ruby, git. The safety model is layered: a non-bypassable hardline floor, explicit permission rules, an approval gate, a shell-confirmation policy, and a workspace sandbox. When run inside an isolated VM, the blast radius is limited to that VM.

## Is it safe to enable shell?

Yes. `tools.shell` is **on by default** because the agent ships to run inside an isolated VM where running commands is the whole point. Every command is still gated: by default `security.require_confirmation_for_shell` is `true`, so each shell command goes through an approval prompt, and a hardline floor blocks catastrophic commands regardless of any setting.

## The approval decision order

`Security::ApprovalPolicy#decide` resolves every tool call in this fixed order. The key invariant: **deny-class checks run before every allow path** — neither the hardline floor nor an explicit `permissions: deny` can be overridden by `yolo`, a `permissions: allow` rule, or the command allowlist.

1. **Hardline floor** (`:deny`) — a floor *below* yolo. Catastrophic, unrecoverable commands are denied unconditionally.
2. **`permissions: deny`** — an explicit deny rule also beats yolo.
3. **yolo / skip-approvals** — allow-exit (the doom-loop guard still applies).
4. **Doom-loop guard** — breaks an autopilot stuck repeating the same call.
5. **`permissions: allow` / `ask`** — remaining explicit rules.
6. **Command allowlist** (prefix match) — pre-approved commands → allow.
7. **Shell confirm policy** — `confirm_all` → ask; `dangerous_only` → ask only if the command matches a dangerous pattern, else allow.
8. **Mode fallback** — `skip` allows; `auto` asks only for high-risk tools; `manual` asks for any risky tool.

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

`security.confirm_policy` (with `security.require_confirmation_for_shell` as a legacy alias):

- **`confirm_all`** (default; alias `true`) — every shell command not otherwise allowed/denied prompts for approval.
- **`dangerous_only`** (alias `false`) — safe commands run unprompted; only commands matching a dangerous pattern prompt. The hardline floor and `permissions: deny` still run first, so this never weakens the floor.

## Command allowlist

Prefix-matched commands pre-approved without a prompt:

```yaml
security:
  command_allowlist:
    - "git status"
    - "git diff"
    - "bundle exec rspec"
```

An **empty** allowlist pre-approves nothing — pre-approval is opt-in.

## Deny/approve scope: once vs session

At the approval prompt you can decide for just this call or for the rest of the session. Session approvals are remembered by a **prefix/pattern class**, not the raw command:

- a **dangerous** command remembers its pattern class (approving `git push --force origin main` once also covers `git push -f other`);
- a **plain** command remembers only the exact command (approving `git status` does not auto-approve `git diff`).

Session approvals live in-process only (an `always`/disk-persistent tier is reserved but not wired). The granularity matches the matcher, so approving `shell ls` never auto-approves `shell rm -rf /`.

## Abandoned approvals

A run parked on a human decision is bounded by `approvals.wait_timeout_seconds` (default 900s / 15 min). On expiry the gate **auto-denies** (never auto-approves) and frees the worker thread, so a closed tab can't park a server worker indefinitely. While a decision is pending, the SSE idle watchdog is suspended for that run so it isn't reaped mid-wait. Set to `null` for an unbounded wait (interruptible only by an explicit run stop — discouraged on shared servers).

## Workspace sandbox

`tools.workspace_strict: true` (default) confines write/edit/delete tools to the workspace root (`terminal.cwd` or `Dir.pwd`). Set it to `false` only if you trust the model plus the approval flow alone to touch any path the process can reach.

## Attachment SSRF guard

URL attachments are fetched only when the host is in `attachments.allowed_hosts` (plus anything in the `ALLOWED_FILE_URL_HOSTS` env var, comma-separated). Loopback hosts (`localhost`, `127.0.0.1`, `::1`) are always allowed. Empty list + empty env = only loopback is fetchable. The file-attachment policy also fails closed: oversize (>25 MB by default), unsafe, or disallowed-kind files are warned and skipped. The same policy gates CLI image attachments (`-i`/`--image`, `@image` tokens, dropped paths, `/paste`): a file that fails classification or the size cap is rejected client-side, before any provider call.

## <a id="autonomous-memory"></a>Autonomous memory tool

The `memory` tool lets the agent write to its own future context. Every write passes the same injection-defense floor as the memory store — a `ThreatScanner` (prompt-injection / exfiltration patterns) plus a per-group character budget — so a fact can't splice tainted or over-budget content into a later system prompt. See [memory.md](memory.md).

## Fake provider guard

The fake LLM provider can short-circuit tool decisions, so `chat` and `server` refuse to boot with a fake model unless `RUBINO_ALLOW_FAKE=1` is set. Production deployments must never set it.

## TLS for the HTTP API

The API binds `127.0.0.1` by default; only expose it (`--host 0.0.0.0` / `RUBINO_API_HOST`) behind TLS or a trusted segment. For a remote HTTP client, set `RUBINO_TLS=1` (or leave a cert in place) and the API serves over a self-signed cert that the client **pins** (no DNS / Let's Encrypt needed). On first boot it generates `cert.pem` + `key.pem` under `$RUBINO_HOME/tls` (CN/SAN = host/IP, ~10y) and reuses them. Hand the public cert to a pinning client with:

```bash
rubino tls-cert   # prints $RUBINO_HOME/tls/cert.pem (generating it if absent)
```

The private key never leaves the box. (refs #69)

Set `RUBINO_ENCRYPTION_KEY` to encrypt stored OAuth tokens at rest (required for the OAuth routes). See [oauth-providers.md](oauth-providers.md).
