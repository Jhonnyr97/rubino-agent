---
name: skill-authoring
description: "Use when you are creating or editing a rubino-agent skill — writing SKILL.md frontmatter, choosing a description, or structuring the body. Also load when the user asks how to author a skill."
---

# Authoring rubino-agent Skills

## When to use

- Creating a new skill via `skill(action: "create", …)`.
- Editing an existing skill via `skill(action: "edit"/"patch", …)`.
- Adding bundled files via `skill(action: "write_file", …)`.
- The user asks "how do I write a skill?" or "what should the frontmatter look like?"
- A review fork (BackgroundReviewJob) is about to distill a new skill.

## Don't use for

- Loading or reading an existing skill — use `skill(name:)` directly.
- Deleting a skill — see `skill(action: "delete", …)`.
- Installing skills from git — use `rubino skills install`.
- Toggling skills on/off — use `/skills enable|disable <name>`.

## Frontmatter

Every SKILL.md starts with YAML frontmatter between `---` fences. The rubino registry reads these fields:

| Field | Required | Notes |
| --- | --- | --- |
| `name` | yes | Kebab-case, ≤64 chars. Defaults to the directory name. |
| `description` | yes | **Must follow the "Use when <trigger-class> — …" convention.** Describe the TRIGGER that warrants loading the skill, not the task it performs. This is the only text future runs see before they decide to load. |
| `version` | no | Semver string. |
| `license` | no | SPDX identifier. |
| `platforms` | no | List: `[macos, linux, windows]`. Absent = all platforms. |
| `languages` | no | List of lowercased language tokens, e.g. `[ruby, python]`. Scopes the skill's auto-surfacing to matching projects. |
| `category` | no | Groups skills in the prompt index, e.g. `"Development"`, `"Data"`, `"DevOps"`. Defaults to `"General"`. |

Minimal valid frontmatter:

```yaml
---
name: my-skill
description: "Use when <trigger-class> — <one-line behavior>."
---
```

## Description convention

Descriptions MUST start with **"Use when "** followed by the trigger class — conditions that make the skill relevant. A good description answers "when should I load this?" not "what does this skill do?".

| Good (trigger-focused) | Bad (task-labeled) |
| --- | --- |
| "Use when debugging timeout errors in Rack applications." | "Debug Rack timeouts." |
| "Use when the user asks you to review code before merging." | "Code review helper." |
| "Use when you are authoring or editing a rubino-agent skill." | "Skill authoring conventions." |

A trigger-focused description is the single biggest lever on reliable auto-activation.

## Body structure

Every skill should follow this shape

```
# <Title>

## When to use
- Bulleted triggers that warrant loading this skill.
- "Don't use for:" counter-triggers so the model knows when to skip.

## <Topic sections>
- Step-by-step instructions.
- Exact commands and code blocks.
- Rubino-specific patterns.

## Common pitfalls
- Numbered list of mistakes and their fixes.

## Verification checklist
- [ ] Checkable post-action verifications.
```

Not every section is mandatory, but the **"## When to use" / "## Don't use for"** pair is the minimum for reliable triggering — they give the model clear boundaries so it loads the skill only when it genuinely applies.

## Prescribe a reliable, self-verifying method

A skill hard-codes a choice for EVERY future run, so two things matter as much as the description:

1. **Reliable method.** Prescribe tools that don't fail silently. If a tool is known to break on a platform — or can exit 0 while producing garbage — say so and prescribe the robust alternative. Don't enshrine the first thing that returned once.

2. **Mandatory output verification.** End the procedure with an explicit step that checks the OUTPUT is actually correct — page count, row count, file re-opens/parses, a sanity assert — and instruct the agent: **do not report success until it passes; never trust a tool's exit code or a "Done" message.** Most real skill failures in practice are an agent trusting a converter/generator that lied.

Real lesson: a Markdown→PDF skill that prescribed `wkhtmltopdf` (whose macOS build silently emits a 0-page blank PDF while printing "Done") with no output check was loaded, followed, and produced blank PDFs reported as "clean, ready to send". The fix was a robust renderer (headless Chrome) plus "count the PDF's pages; if 0, it FAILED — say so, don't claim success". A skill without §2 would have shipped the same bug to every future run.

## Skill creation

The `skill` tool writes to the agent HOME skills dir (`RUBINO_HOME/skills/` or `~/.rubino/skills/`), never the cwd. Two paths:

1. **Inline creation** — during a turn:
   ```
   skill(action: "create",
         name: "kebab-case-name",
         description: "Use when <trigger-class> — …",
         body: "# Title\n\n## When to use\n- …\n\n…")
   ```

2. **Review-fork distillation** — after a complex, repeatable task, BackgroundReviewJob runs a restricted review turn. It sees the full conversation and the existing skill catalogue. It writes skills via the same `skill(action: "create"/"edit"/"patch"/"write_file")` path — no separate API.

## Built-in vs authored skills

Bundled skills (shipped in the gem under `skills/`) are protected — the review fork and inline edits cannot overwrite them. To customize a bundled skill, create a same-named skill under `~/.rubino/skills/` or `.rubino/skills/` — it will override the built-in on discovery (last writer wins).

## Common pitfalls

1. **Description is task-labeled, not trigger-focused.** "Extract text from PDFs" won't help a future session decide whether to load the skill. "Use when the user gives you a PDF and asks for its text" will. Always start with "Use when ".

2. **Missing "## Don't use for" counter-triggers.** Without them, the model may load the skill for a tangentially related task and follow instructions that don't apply. A skill about PDF extraction should say "Don't use for: scanned images (use the OCR skill instead), forms (use the form-fill skill)."

3. **Name is session-specific, not class-level.** "fix-nil-error-2025" only makes sense today; "ruby-nil-safety-patterns" applies forever. If the name includes a date, PR number, or error message, it's wrong.

4. **Duplicating an existing skill.** Before creating, check the "## Skills" catalogue in your system prompt — if a skill already covers this territory, patch or edit it instead.

5. **Writing to the wrong location.** The `skill` tool writes to the agent HOME, not the gem's `skills/` directory. If you're adding a bundled skill that should ship with the gem, use `write`/`write_file` to `skills/<name>/SKILL.md` and `git add` it. The `skill` tool creates user skills; the filesystem creates bundled skills.

6. **Enshrining a tool that lies, or no output check.** The most damaging skill is one that prescribes a silently-failing tool (or trusts an exit code) so every future run produces broken output reported as success. Prescribe a robust method and make the last step verify the actual output — see "Prescribe a reliable, self-verifying method".

## Verification checklist

- [ ] Description starts with "Use when " and describes the trigger class.
- [ ] Body has "## When to use" and "## Don't use for" sections.
- [ ] Name is kebab-case, ≤64 chars, class-level (no session artifacts).
- [ ] No duplicate of an existing skill.
- [ ] Pitfalls section covers known gotchas.
- [ ] Each ordered step has a checkable completion criterion.
- [ ] The procedure prescribes a reliable method (no silently-failing tool, or its failure is called out).
- [ ] The procedure ends with an output-verification step that does not trust the exit code / "Done".
