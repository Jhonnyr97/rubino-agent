# task.md — contesto di lavoro rubino-agent (handoff)

> File di contesto per una futura istanza di Claude + per Nilthon. Dice **cosa stiamo
> facendo**, **come lavoriamo**, lo **stato**, e i **prossimi passi con i prompt pronti**.
> (Chat in italiano; contenuti GitHub/commit in inglese.)

## STATO 2026-07-11 (ultima sessione Claude) — DSL slice 1 + 4 fix da mandare
- **DSL `Rubino::Tool` slice 1 FATTO da rubino-dev** (branch `feature/rubino-tool-dsl`, **UNCOMMITTED** nel working tree: `lib/rubino/tool.rb` 424 righe, `demo_export_tool.rb`, `tool_spec.rb`, rewrite `vision_tool`, tool riorganizzati in sottocartelle `tools/{files,shell,task,web,memory,misc,attachment}/`). Review Claude: **core solido e sicuro** — 48 spec verdi, redaction default `:shell`, guardie image PRIMA del body, footgun ereditarietà risolto (copy-down ivars), auto-registrazione via `inherited` che salta abstract/anonimi. Il paletto sicurezza regge.
- **agentskills.io compliance COMMITTATO** su test (`e80d3d01`) + webfetch spill (`9fa78928`). Commit tutti in inglese, nessun italiano nei committati.
- **4 FIX diagnosticati (root cause inchiodata) + brief pronti in `dev-prompts/` — mandali a rubino-dev uno alla volta:**
  1. `fix-skills-shadow-warning.txt` — warning "shadows" self-referenziale spam sulla TUI. Causa tripla: (a) `discover!` (registry.rb:97-115) scansiona la stessa dir 2× quando `.rubino/skills` risolve = `~/.rubino/skills` (lanci da $HOME) → manca dedup per realpath; (b) `warn`→stderr bypassa il file-logger (logger.rb:50-55 #125) e sporca il frame; (c) l'override cross-dir è ATTESO (agentskills.io project>user) → non è un warning, va a debug/una-volta. Fix: dedup realpath + `warn`→`Rubino.logger` (anche skill.rb, markdown_loader.rb) + once/debug.
  2. `fix-clear-dump-timeline.txt` — dopo `/clear` il dump collassa le tabelle multi-riga su una riga con ` — `. Causa: `SessionResolver#replay_message` ramo `"tool"` (session_resolver.rb:189-205) chiama solo `tool_started`+`tool_finished`, OMETTE il body; il metric-less Result cade su `truncated_preview`→`truncate_inline` (cli.rb:3256 `join(" — ")`). Fix: replay `ui.tool_body(msg.content, kind:)` tra i due.
  3. `fix-dropdown-realtime.txt` — dropdown si aggiorna solo a fine loop, status bar no. Causa: status bar ha ticker 0.1s uncoalesced; dropdown dipende da `set_cards` COALESCED (`return if capped == @cards`, bottom_composer.rb:775) che è cieco al picker aperto (allora i rows vengono da `@agent_menu.rows`). Fix: `return if capped == @cards && !@agent_menu.open?` + bump cadenza ticker quando aperto + mirror in IdleCardHost. Paletto concorrenza: repaint dentro `@render` mutex, refresh via `rows`→`refresh!` (mai `open!`), niente thread nuovo.
  4. `fix-dsl-slice1-fixups.txt` — [BLOCCANTE] `DemoExportTool` SPEDISCE in produzione (auto-registrato+abilitato, loop ~15s) — spostarlo fuori dal glob `tools/`; [BLOCCANTE] `demo_export_tool.rb` è tutto in ITALIANO (commenti + `describe`/`ok`/`metrics` shippati) — riscrivere in inglese; [MINORE] messaggio egress-off ha perso il config-key hint + spec indebolita — ripristinare; [LATENTE] `inherited` registra prima che giri il body (tool.rb:72) — fixare o documentare.
- **Metodo verifica**: 5 subagent Claude read-only hanno diagnosticato dropdown/clear-dump/DSL + lifecycle B/C + attached-view A; io ho riprodotto il self-shadow direttamente. Il CODICE dei fix lo fa rubino-dev.

## STATO 2026-07-11 (2ª parte) — i 4 fix APPLICATI da rubino-dev + 3 nuovi comportamenti diagnosticati
- **I 4 fix sono nel working tree** (uncommitted): shadow (registry/skill: 0 warning ora, verificato), clear-dump main (session_resolver +replay_spec), dropdown repaint (bottom_composer/cli/idle_card_host), DSL fixup (demo→`examples/` fuori dal glob + inglese, `tool.rb`, vision −91 righe). **194 spec verdi** su skills+replay+tool+vision. Italiano: zero (solo `task.md` è italiano, ma è handoff interno untracked).
- **3 comportamenti reali ancora aperti (utente li vede live), diagnosticati → brief `dev-prompts/fix-realtime-bg-lifecycle.txt` (A+B+C insieme, stesso sottosistema):**
  - **B** elemento finito non sparisce dalla dropdown fino a fine turn: NON è reaping (l'entry lascia `#running` subito) ma **repaint gated** — `refresh_live_cards` (cli.rb:1037-1041) salta il paint quando `running.any?` è falso → la transizione-a-vuoto non si disegna mid-turn; subagent forzano il repaint, inline/shell no. Fix: rilassare il guard (mirror `IdleCardHost#paint`).
  - **C** "done" del bg visibile solo a fine loop: il path model-facing (InputQueue drain, loop.rb:423-451) è INTENZIONALE (ordering, non toccare); il marker UI "✓ done" è stashato in `@pending_subagent_footers` finché `@turn_active` (cli.rb:906-913) — deferral cosmetico. Fix: surface live via `commit_async_above`, InputQueue intatto.
  - **A** entri nell'inline live_card → clear+dump → timeline vuota: lo stdout vive SOLO nel `@buffer` dell'`InlineToolAdapter`, cancellato all'istante del finish (`tool_executor.rb:369-372` unregister_inline). Non persistito da nessuna parte. Fix: **trattenere** l'adapter (finish! ma no unregister; reap limitato) così `find(id)` continua a tornarlo e `paint_shell_tail(output_all)` ridisegna.
  - PALETTO concorrenza (tutti e 3): repaint SOLO via composer mutex-safe (set_cards/commit_async_above/print_above, parkano sotto modali), mai `emit` raw da thread figlio; niente busy-repaint a vuoto+chiuso.
- **Brief di test E2E tmux**: `dev-prompts/test-tmux-e2e-verify.txt` — rubino-dev pilota una rubino reale in tmux, 6 scenari (shadow/clear-dump/dropdown-live+dispare/done-live/attached-survive/DSL-hygiene) con cattura pane come prova. Da lanciare DOPO il fix.
- **Git hygiene fatto (2026-07-11)**: `agent.md`+`task.md`+`dev-prompts/` untracked+gitignored (staged D, su disco); `examples/demo_export_tool.rb` gitignored (mai in storia). History-scrub vero = batch §APERTO 2 ad albero pulito.

## STATO 2026-07-11 (3ª parte) — Claude HANDS-ON sui 3 comportamenti live (utente: "te ne occupi direttamente tu")
Il refactor `ShellTailer` di rubino-dev NON aveva risolto. Claude ha fixato direttamente (branch `feature/rubino-tool-dsl`, uncommitted):
1. **Vista attaccata FRIZZATA — ROOT CAUSE + fix**: `ShellTailer#paint_full/paint_delta` erano `(composer, entry, origin:)` ma TUTTI i chiamanti passano `(entry, origin:)` → `ArgumentError` a ogni chiamata, ingoiato dal `rescue` del status ticker → nessun paint. Il file era **senza spec**. Fix: legato il composer al tailer alla creazione (`ShellTailer.new(self)` in bottom_composer), tolto il param spurio; +5 spec `shell_tailer_spec.rb` che pinnano la forma di chiamata reale.
2. **Nested-def in `cli.rb`**: `refresh_live_cards` senza `end` → `tail_attached_shell` annidato nel rescue (definito solo dopo un raise). Un-nested.
3. **Bug B (card resta fino a fine turn)**: `refresh_live_cards` ora dipinge la transizione-a-vuoto anche a picker chiuso via tracking `@had_live_cards` (il fix di rubino-dev copriva solo picker aperto). Spec 1263 resta verde.
4. **Bug C (output bg al modello solo a fine loop)**: non è l'auto-wake (funziona) — è il **timing**. `loop.rb` ramo `if response.text_only?`: se una notice bg è pendente all'uscita, NON finalizzare → `persist + close_intermediate_stream + next` così `inject_steered_input` la consegna alla prossima iterazione (**mid-turn**), non all'idle auto-wake. + wording `coalesced_resume_prompt` generalizzato (shell+subagent). +1 spec loop `#561 mid-turn`.
5. **Spec rossa lasciata da rubino-dev**: `cli_post_turn_ticker_spec:196` asseriva il vecchio fold-nel-footer; aggiornata al nuovo contratto (subagent_finished surface LIVE). 
Verifica: ui+cli/chat+tools+agent tutti verdi tranne `shell_registry_pty_spec:25` (host-flaky noto). rubocop pulito. **Da verificare in tmux come umano** dall'utente (attach a un run lungo → output scorre; card sparisce a fine processo; bg result arriva mid-turn).

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
2. **History-scrub + force-push — BATCH UNICO** (CONFERMATO "si esatto" + "rimossi dalla storia" 2026-07-11). Da eseguire **ad albero pulito** (dopo aver committato i fix verificati), in UN solo passaggio `git filter-repo` per non fare force-push doppi sullo stesso branch:
   - **(a) Rimuovi dalla storia i file interni** (già untracked+gitignored nel working tree, ma restano in history): `agent.md` (da `c7597907`), `task.md` + `dev-prompts/` (da `8c1ad40f`). Tecnica: `git filter-repo --path agent.md --path task.md --path dev-prompts/ --invert-paths`. NB: `examples/demo_export_tool.rb` NON è in storia (mai committato) → solo gitignored, fuori dal batch.
   - **(b) Reword framing "Claude Code compat"→"markdown extensions"** nei messaggi dei 5 commit compat + docs (`--message-callback`), e **rinomina branch** `feature/claude-code-compat`→`feature/markdown-extensions`.
   - Poi **force-push** `test/pre-release-gate` + il branch rinominato. Playbook: memoria `reference_git_history_scrub`. ⚠️ force-push riscrive storia condivisa di test — con calma, non di fretta, e SOLO con l'albero pulito (filter-repo pretende tree pulito → il lavoro non committato di rubino-dev va prima committato/verificato).
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
