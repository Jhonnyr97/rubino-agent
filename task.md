# task.md — contesto di lavoro rubino-agent (handoff)

> File di contesto per una futura istanza di Claude + per Nilthon. Dice **cosa stiamo
> facendo**, **come lavoriamo**, lo **stato**, e i **prossimi passi con i prompt pronti**.
> (Chat in italiano; contenuti GitHub/commit in inglese.)

## Metodo di lavoro (IMPORTANTE — rispettalo)
- **Il codice di rubino NON lo scrive Claude.** Si delega:
  - **rubino-dev** (`~/.local/bin/rubino-dev`, gira dal checkout, RUBINO_HOME=/tmp/rubino-dev, contro ds4 locale) per il **filone estensioni/DSL** (l'utente lo preferisce qui).
  - **hermes** (`~/.local/bin/hermes`) per fix/verifiche generiche.
  - Invocazione: `rubino-dev chat -q "$(cat prompt.txt)" --yolo --max-turns N` / `hermes chat -q "..." --yolo --max-turns N`.
  - ds4 è LENTO → usa **budget alti** (200–250) per rubino-dev, altrimenti taglia a metà.
  - Output live sempre su **file a nomi fissi**: `tee -a /tmp/rubino-dev/hermes.log` (narrazione) e `/tmp/rubino-dev/session.log` (pane tmux). Symlink in scratchpad. L'utente tail-a sempre quelli.
- **Claude orchestra e VERIFICA read-only** (grep/rspec/rubocop), un **brief razoio + uno slice alla volta**, poi committa (i git-op li fa Claude). Niente rspec inline macinato: se serve girare tanto, delega.
- **Test E2E in tmux**: hermes guida una sessione `rubino-dev` in tmux (rubino non pilota la propria TUI). Cattura pani come prova.
- **Un branch per feature**, poi merge in `test/pre-release-gate`. **Niente push/PR/merge senza ok esplicito.** Niente attribuzione Claude nei commit. Niente force-push senza ok esplicito.
- Failure host ricorrenti = NON regressioni: `executor_dirs_spec:64` (/dirs env), `shell_registry_pty_spec:25` (PTY), ~EPERM sandbox su `approval_policy`/`ruby_tool`/`tool_fixes` (flaky). Verifica in isolamento prima di allarmarti.

## Cosa abbiamo fatto (questa sessione) — tutto su `test/pre-release-gate` (pushato)
1. **ruby_llm-native tools + MCP** (branch `refactor/ruby-llm-native-tools`): tool→`params do` DSL, split Security/Presentation, redaction pluggable; MCP wrapper first-class + **resources/prompts come tool per-server capability-gated** + notifications→mcp.log. (audit: teniamo model-registry nostro; error/thinking rimandati — vedi memoria `project_rubino_rubyllm_alignment_audit`).
2. **bg crash-safe logging** (`feature/bg-crash-safe-logging`): subagent scrive transcript `.jsonl`, shell `.log`; il padre legge; path nell'handle.
3. **tool-live-card** (`feature/tool-live-card`): DSL `live_card ->(args){…}` opt-in → il tool appare nella dropdown multiplexer, ⏎ clear+timeline, ← torna (riusa attach esistente). E2E ok.
4. **tool-presentation-approval** (`feature/tool-presentation-approval`): approval-preview → `ToolPresentation#preview_arguments`.
5. **markdown extensions** (branch `feature/claude-code-compat` — DA RINOMINARE, vedi sotto): rubino carica **agents/skills/commands/rules da file `.md`** (skills=agentskills.io, rules=catena `RUBINO.md`→`AGENTS.md`→`CLAUDE.md`→`.cursorrules`, commands `.md`, agents `.md`→`Agent::Definition`), da `~/.rubino/…` e `~/.claude/…`, **trust-gated**, + **`Security::ContentScanner`** anti-prompt-injection su tutto il contenuto esterno. E2E in tmux 4/4. (memoria `project_rubino_claude_code_compat`, `reference_hermes_extension_methodology`.)

WIP non finiti/non in test: `feature/inline-tool-adapter-wip` (superato da live-card), `feature/bg-subagent-resume` (stash resume-framing, da finire).

## APERTO — da chiudere (ordine)
1. **Ri-framing docs** (NON ancora fatto): la pagina è `docs/claude-code-compat.md` col titolo "Claude Code / everything-claude-code Compatibility" — **framing SBAGLIATO**. La feature è **generale** (estensioni markdown portabili); everything-claude-code è solo *un esempio*. → `git mv` a `docs/markdown-extensions.md`, retitle "Markdown extensions: agents, skills, commands & rules", ri-scrivi l'INTRO (capacità di rubino, `~/.claude` come sorgente/esempio, non lo scopo), tieni il corpo tecnico; aggiorna il link in README. **[Claude può farlo forward come commit docs.]**
2. **History-rewrite + force-push** (CONFERMATO dall'utente "si esatto"): togliere il framing "Claude Code compat" dalla **storia** — reword messaggi dei 5 commit compat + docs commit ("…interop/compatibility"→"markdown extensions"), **rinomina branch** `feature/claude-code-compat`→`feature/markdown-extensions`, poi **force-push** `test/pre-release-gate` + branch. Tecnica: `git filter-repo --message-callback` (playbook memoria `reference_git_history_scrub`). ⚠️ force-push riscrive storia condivisa di test — farlo con calma, non di fretta.
3. **Verifica agentskills.io**: rubino-dev conferma che lo skill-loading è conforme allo standard agentskills.io (campi/struttura/comportamento) per chiudere il filone. Prompt: `dev-prompts/agentskills-verify.txt`.

## PROSSIMO GRANDE LAVORO — DSL `Rubino::Tool` (approvato "sembra fantastico")
Un subagent critico ha rivisto l'authoring dei tool. **Diagnosi:** la macchina è ottima, è la *facciata di authoring* il problema — 5 spazi-concetto slegati (`params`/`security`/`presentation`/`presentation_cli`/`live_card`) + return-contract implicito (String / Hash a ~11 chiavi / `Tools::Result`, 3 modi di errore) + due DSL divergenti (`Tools::Base` vs `Rubino.define_tool`) + footgun d'ereditarietà (`@tool_security` class-ivar non eredita) + tool immagine/aux con ~40 righe di guardie egress copiate a mano.

**Proposta:** `Rubino::Tool < Tools::Base` = sugar-layer che **sintetizza** gli oggetti Security/Presentation/Result esistenti (come già fa `CustomToolLoader#build`). Macro: `describe`, un solo spelling param (`string :x, "desc", default:`), `risk`, `renders :diff/:json`, `require_read!`, `streams card: ->`, `uses_aux :vision`, param-type `image` (folda workspace+sniff+egress GRATIS), helper risultato `ok`/`error(code:)`/`attach`/`attach_image`, **auto-registrazione** via `inherited`, copy-down degli ivars (uccide il footgun). Un tool passa da ~45 righe/4-concetti a ~12 leggibili. Filosofia: **semplice, magico-per-convenzioni, ma ogni default overridabile** (fino a `security_class MySec`).

**PALETTO DI SICUREZZA (non negoziabile):** la magia NON deve MAI allargare in silenzio i permessi/redaction. `redaction :none` (spegne lo scrubbing segreti) deve restare **esplicito**, mai inferito. Ground default `:shell`; si *restringe* solo su dichiarazione esplicita. Non toccare i chokepoint dell'executor (redaction/compression/approval), la workspace-canonicalization, il vocabolario di deny di `Tools::Result`.

**Piano a slice** (build-on-not-rewrite, back-compat, uno alla volta con rubino-dev budget alto, poi Claude verifica):
- **Slice 1 (pilota, massimo valore):** la classe base `Rubino::Tool` + helper risultato `ok`/`error` + un solo spelling param + auto-registrazione + copy-down ivars; e il **tool immagine** (`image` param-type con guardie egress + `uses_aux`/`ask_aux` + `attach_image`) come dimostrazione, riscrivendo `vision_tool` (e/o un generate-image) sopra. Prompt: `dev-prompts/rubino-tool-dsl-pilot.txt`.
- Slice 2: macro `risk`/`renders`/`require_read!`/`preview do…end` → migra `edit`/`multi_edit`.
- Slice 3: `streams card: ->`/`stream(text, as:)` → migra `shell`; converge `Rubino.define_tool` (shim deprecato).
- A ogni slice: mostra **before/after** e un tool banale ~12 righe; test verdi; rubocop.

## Prompt pronti (mandali tu a rubino-dev)
- `dev-prompts/rubino-tool-dsl-pilot.txt` — slice 1 (base DSL + tool immagine).
- `dev-prompts/agentskills-verify.txt` — verifica conformità agentskills.io.
Uso: `cd <checkout> && rubino-dev chat -q "$(cat dev-prompts/<file>.txt)" --yolo --max-turns 250 2>&1 | tee -a /tmp/rubino-dev/hermes.log | tail -40`

## Stato git (a fine sessione)
- `origin/test/pre-release-gate` = tutto integrato + docs (framing ancora da correggere).
- `origin`: `refactor/ruby-llm-native-tools`, `feature/{claude-code-compat,bg-crash-safe-logging,tool-live-card,tool-presentation-approval}`.
- Locali non pushati: WIP `inline-tool-adapter-wip`, `bg-subagent-resume`.
