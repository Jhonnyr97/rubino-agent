# Porting Hermes' interactive PTY shell to rubino

Status: DESIGN (deep-study of Hermes, no impl yet) · Branch: `feat/bg-shell-ux`
Source studied: `hermes-agent/tools/process_registry.py`, `hermes-agent/tools/terminal_tool.py`,
`hermes-agent/hermes_cli/pty_bridge.py`.

## Why PTY (the corrected conclusion)

A pipe-backed background shell has `stdin=DEVNULL` and can't answer `y/N`, sudo passwords,
or run TTY-aware/curses programs. Hermes (and Codex `unified_exec`, and the open Claude
Code FR) all converge on a **PTY**: the process believes it's on a real terminal, and the
user's keystrokes/answers are written to the PTY master. We follow Hermes.

## Hermes' model (the algorithm we port, with refs)

1. **Spawn.** `ProcessRegistry.spawn_local(use_pty=True)` (`process_registry.py:515`) →
   `ptyprocess.PtyProcess.spawn(cmd, env, ...)` (`:553`); the handle is stored on
   `ProcessSession._pty` (`:134`). Pipe fallback when ptyprocess is absent. Pipe mode is
   `stdin=DEVNULL` (`:605`) — deliberately non-interactive.
2. **Output reader.** `_pty_reader_loop` (`:814`) `pty.read(4096)` until `pty.isalive()` is
   false; captures `exitstatus`. Feeds `_check_watch_patterns` on each chunk (`:748/784/828`).
3. **Input primitives.** `write_stdin(id, data)` (`:1184`) → `_pty.write(bytes)`;
   `submit_stdin(id, data="")` = `write_stdin(data + "\n")` (press Enter, `:1209`);
   `close_stdin(id)` = EOF without kill (`:1213`).
4. **Interactive prompt routing.** Thread-local UI callbacks: `set_sudo_password_callback`
   / `set_approval_callback` (`terminal_tool.py:189-205`). When unset, fall back to
   `/dev/tty` / `input()`. The CLI registers them so prompts run through the TUI event loop.
5. **Sudo password.** Detect `sudo` (`_rewrite_real_sudo_invocations`, `:501`), prompt the
   user with HIDDEN input ("input is hidden", `:404`), cache per scope
   (`_sudo_password_cache`, scope = session-key / callback-owner / thread, `:205-240`), feed
   it to the process. Cache cleared on teardown (`_reset_cached_sudo_passwords`).
6. **Watch patterns.** Regexes scan new output to detect notable lines/prompts; after
   `WATCH_STRIKE_LIMIT` (3) misses, disable + promote to `notify_on_complete` (`:191-288`).

## rubino mapping (DRY, faithful, clean-code)

rubino already has the skeleton: `Tools::ShellRegistry` (pgid tracking + kill),
`shell_tool` (background spawn), `shell_input`/`shell_output`/`shell_tail`/`shell_kill`.
Today it is **pipe-only**. The port adds a PTY mode alongside.

| Hermes | rubino target |
|--------|---------------|
| `ptyprocess.PtyProcess.spawn` | Ruby stdlib **`PTY.spawn`** (`require "pty"`) — returns `[reader_io, writer_io, pid]` |
| `ProcessSession._pty` | a `pty_master`/`pty_pid` field on `ShellRegistry::Entry` (`shell_registry.rb:31`) |
| `_pty_reader_loop` | the existing `drain_into` reader, reading the PTY master instead of the pipe |
| `write_stdin/submit_stdin/close_stdin` | extend `ShellRegistry.write_input` + add `submit_input` (`+"\n"`) and `close_input` |
| sudo/approval UI callbacks | **reuse rubino's existing prompt UI** (`UI::CLI#confirm` / the `question` tool / approval menu) — register a thread/fiber-local "shell input needed" callback that surfaces a masked prompt |
| `_sudo_password_cache` (per scope) | a per-session masked-secret cache (scope = session id), cleared on teardown; mask in scrollback via the existing `SecretsMask` |
| watch_patterns | OPTIONAL (slice 3) — a prompt detector (`password:`, `[y/N]`) to auto-surface input without the user attaching |

### How the USER provides the `y` / password (the goal)

Two complementary paths, both writing to the same `write_input` PTY primitive:

- **Attach-and-type (the focus view).** When attached to the shell (the bg-shell-as-
  `BackgroundTasks`-entry from `bg-shell-ux.md`), your keystrokes/lines route to
  `ShellRegistry.write_input(id, ...)` → the PTY. You see `[y/N]`, type `y`, it goes in.
- **Detect-and-prompt (Hermes sudo path, no attach needed).** A registered callback +
  a prompt detector surface a masked/normal prompt inline ("the shell wants input:
  `Password:`"); your answer is written to the PTY. Reuses the `question`/approval UI.

## Stages (each clean-code, spec'd, tmux-verified before the next)

- **Slice 0 — PTY foundation.** `ShellRegistry` gains a PTY mode (`PTY.spawn`), the reader
  reads the master, `write_input`/`submit_input`/`close_input` work over the PTY. The model
  tools (`shell_input`) already call `write_input`, so the agent can drive an interactive
  bg process. Verify in tmux: `python3 -c "print(input('name? '))"` in bg, `shell_input`
  "x\n", output shows it. (No user-facing UI yet.)
- **Slice 1 — SEE + STOP + FOCUS** (from `bg-shell-ux.md`): shell as a `BackgroundTasks`
  `kind: :shell` entry → card + picker + `/stop` + attach view (clear + live PTY tail).
- **Slice 2 — USER types in focus.** Attached keystrokes/lines → `write_input` (the PTY).
  Now you answer `y` yourself in the focus view.
- **Slice 3 — detect-and-prompt + sudo masked.** Prompt detector + masked password +
  per-session cache, reusing the `question`/approval UI. The Hermes sudo flow.

## Gotchas (from the source)

- `PTY.spawn` makes the child a session leader (PID == PGID) — matches rubino's existing
  pgid hard-kill, good. But PTY EOF/`Errno::EIO` on child exit must be caught in the reader
  (Ruby's `PTY` raises `PTY::ChildExited`/`Errno::EIO`).
- Terminal size: a PTY needs a winsize (`TIOCSWINSZ`); set a sane default (e.g. 120x40) or
  the attached terminal's size; resize on attach.
- Masking: the sudo/secret path MUST run answers through `SecretsMask` so the password
  never lands in scrollback or the output buffer (Hermes hides it; rubino has `SecretsMask`).
- Don't break the pipe path: keep pipe mode as the default for non-interactive bg work;
  PTY mode is opt-in (a `pty: true`/`interactive: true` arg, or auto when a prompt is likely).
- Output: a PTY echoes input back + emits control sequences; the output buffer/tail must
  strip/normalize (rubino has `ansi_strip`-equivalent? confirm) so the model/user see clean text.
