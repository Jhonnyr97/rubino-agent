# Review-driven refinements (Slice 1 design lock-in)

An adversarial clean-code review of Slice 0 + the bridge plan produced these changes.
They supersede the "thin adapters" framing in `bg-shell-ux.md` where they conflict.

## Slice 0 fixes already applied (from review)

- **close_stdin crash-on-retire (BLOCKER):** EOT only a LIVE child; a dead PTY master
  raises `Errno::EIO`, so close the fd instead (also reclaiming a leaked `master_w`).
  Rescue widened to `IOError, Errno::EIO, Errno::EBADF`.
- **spawn_pty cwd fragility:** `cd … || exit 127\n<cmd>` (own line) — not `cd && (<cmd>)`,
  which a trailing `#`-comment broke.
- **winsize:** default `40x120` (a fresh PTY is 0x0).
- Honest comments (EOT is canonical-mode-only; dropped the dead `PTY::ChildExited` catch).

## Still-open Slice 0/2 prerequisites (do BEFORE wiring write_input/attach)

- **PTY echo:** a cooked PTY echoes typed input back into the buffer → doubled text, and a
  typed password would land in the ring buffer in cleartext. Before the user/agent writes
  to a PTY: turn `ECHO` off via `io/console` for the secret path, and/or strip the echoed
  line at the capture seam. Mask through `SecretsMask`.
- **Control sequences:** a PTY emits `\r\n` + CSI/OSC. `drain_into` only `scrub_utf8`s.
  For PTY mode, normalize at the capture seam (strip CR, strip non-SGR CSI/OSC) so the
  model isn't fed escapes and the attach view doesn't paint raw escapes (route the attach
  renderer through the same `sanitize_terminal_keep_sgr` the cards use — CWE-150).

## DRY: the `kind:` discriminator is a DATA TAG, not a control switch

Review verdict: a `case kind` would spray across ≥7 sites (stop_entry, attach view,
attached-input, cards, menu, watch, completion) — a smell. Instead:

1. Give the shell's `BackgroundTasks` entry the **same flat fields** the renderers already
   read (`prompt`=command, `started_at`, synced `status`, `subagent`="shell"). Then
   `SubagentCards`, `AgentMenu`, `render_agent_watch` need **zero** branches. Replace the
   literal `"subagent"` strings with one `entry_kind_label(entry)` helper.
2. Push the genuinely-divergent behavior behind **~4 polymorphic methods on the entry**
   (or two small duck-typed adapter objects): `#stop`, `#attach_render(ui)`,
   `#feed_input(text)`, `#live?`. Then `stop_entry` → `entry.stop`, `attach_agent_view` →
   `entry.attach_render`, `handle_attached_input` → `entry.feed_input`. **No `case kind`
   in any UI file.** `kind` survives only as the label.

## Three gaps to handle when registering a shell entry

`BackgroundTasks#reserve` carries subagent semantics a shell must NOT inherit:

1. **Concurrency cap:** `reserve` counts against `max_concurrent_total`/depth/per-owner. A
   shell is not an LLM run — it must register WITHOUT consuming the subagent budget
   (separate register path, or exempt `kind: :shell` from `running_count`/`refusal_reason`).
2. **Double completion notice:** `ShellRegistry#notify_completion` ALREADY pushes
   `[background-shell] finished`. If the BG entry's `complete` also fires a notice, the user
   gets two. Pick ONE owner (keep ShellRegistry's; the BG entry only syncs status).
3. **Dead steer_queue:** `reserve` allocates a `steer_queue`; a shell can't steer/probe.
   Disable steer/probe for `kind: :shell` (route attached input to `feed_input` → stdin).

## Status sync note

Two status sources (ShellRegistry `wait_thr`-derived vs BG stored): sync the BG entry to
terminal only at `notify_completion`. There's a small window where a just-killed shell still
reads live until the reader thread fires — acceptable, documented.

## Sandbox/pgid: confirmed intact under PTY.spawn

`PTY.spawn` setsid's the child → `pgid == pid` (pgroup:true redundant); the sandbox launcher
still `exec`s bash in place, so the write-jail + pgid-kill are identical to the pipe path.
Only cwd handling diverged (fixed above).
