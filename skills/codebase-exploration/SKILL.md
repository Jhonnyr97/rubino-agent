---
name: codebase-exploration
description: "Use when dropped into an unfamiliar codebase — 'explore this repo', 'how is this project structured?', 'what does this codebase do?', 'onboard me'. Systematic methodology: entry points, architecture, data flow, key abstractions. Builds a mental model before making changes."
version: 1.0.0
license: MIT
category: "Development"
---

# Codebase Exploration

Systematic methodology for understanding an unfamiliar codebase. Build a
mental model before making changes — read first, then act.

**Core principle:** You can't fix what you don't understand. Investment in
exploration pays back in correct first-attempt changes.

## When to use

- Dropped into a new repository for the first time
- "explore this repo" / "how is this project structured?"
- "what does this codebase do?" / "onboard me"
- Before making changes to code you've never touched
- Before proposing architectural changes

## Don't use for

- Looking up a single known file or symbol — just read/grep it directly
- A small, scoped edit in an area you already understand
- When you already have a working mental model of the repo

## The Exploration Process

### Phase 1 — Surface Scan (5 min)

Get the lay of the land with zero assumptions:

```bash
# What kind of project is this?
ls -la

# Check for project documentation
ls README* CONTRIBUTING* ARCHITECTURE* docs/ 2>/dev/null

# Top-level directory structure
ls -d */ 2>/dev/null

# Language breakdown by file count
find . -type f -not -path '*/.git/*' -not -path '*/node_modules/*' \
  -not -path '*/vendor/*' | sed 's/.*\.//' | sort | uniq -c | sort -rn | head -15

# Git stats for context
git log --oneline | wc -l           # Project age
git shortlog -sn | head -5          # Top contributors
git tag | tail -5                   # Recent releases
```

Read the README.md. This tells you the project's purpose in the maintainer's
own words.

### Phase 2 — Entry Points (10 min)

Find where execution begins:

```bash
# Ruby
grep -r "def self.call\|class.*Application" lib/ --include="*.rb" -l | head -10

# Find executables
ls bin/ exe/ 2>/dev/null

# Find the main entry file
grep -r "require.*boot\|require.*application\|require.*environment" --include="*.rb" -l | head -5
```

Identify:
- CLI entry point (bin/ file, main class)
- Web server entry (config.ru, Rack app)
- Library entry (main require file)
- Config/bootstrap files

### Phase 3 — Architecture Map (15 min)

Build a structural understanding. Read the top-level files in the key
directories, not the internals:

1. **Config files** — `Gemfile`, `config/`, `.env.example`, `config.yml`.
   These tell you what external services the project depends on (database,
   Redis, external APIs, background jobs).

2. **Top-level modules** — Read the directory listing and identify
   architectural boundaries:

```bash
# List first-level directories with their sizes
du -sh */ 2>/dev/null | sort -rh
```

3. **Gem/package dependencies** — The dependency list is a map of
   architectural decisions:

```bash
# Ruby
grep "^gem" Gemfile | head -20

# Node
jq '.dependencies | keys' package.json 2>/dev/null
```

4. **Key abstractions** — Find the core domain models and services:

```bash
# Ruby — find models
grep -r "class.*<.*ApplicationRecord\|class.*<.*ActiveRecord::Base" app/models/ --include="*.rb" -l

# Find service objects
grep -r "class.*Service\|module.*Service" lib/ app/ --include="*.rb" -l | head -10
```

### Phase 4 — Data Flow (15 min)

Trace one complete path through the system:

1. **Pick a user action** — "create a user", "process a payment", "generate a
   report"
2. **Find the controller/endpoint** for that action
3. **Follow it down** through the service layer, models, database
4. **Follow it up** through views, API responses, side effects (emails, jobs)

```bash
# Find routes/endpoints
grep -r "get\|post\|put\|delete\|patch" config/routes.rb 2>/dev/null | head -20

# Find controllers handling a specific resource
grep -r "class.*Controller" app/controllers/ --include="*.rb" -l
```

Use rubino's tools to read key files:

```
read("app/controllers/users_controller.rb")
read("app/services/user_creator.rb")
read("app/models/user.rb")
```

### Phase 5 — Test Structure (10 min)

Tests reveal intent and expected behavior:

```bash
# How are tests organized?
ls spec/ test/ 2>/dev/null | head

# Run a quick test count
find spec/ test/ -name "*_spec.rb" -o -name "*_test.rb" 2>/dev/null | wc -l

# Read a few test files for the key domain objects
```

Tests are often better documentation than comments — they show what the code
is *supposed* to do, not just what it happens to do.

### Phase 6 — Summarize

Output a structured summary:

```markdown
## Codebase Summary: <project>

### What It Does
[2-3 sentences from README + your understanding]

### Tech Stack
- Language: Ruby X.X / Python X.X / Node X.X
- Framework: Rails / FastAPI / Express / ...
- Database: PostgreSQL / SQLite / ...
- Key dependencies: [list 5-10 most important]

### Architecture
- **Entry point:** <file>
- **Layers:** Controller → Service → Model → DB
- **Key abstractions:** [3-5 core models/services]
- **External services:** [list APIs, queues, caches]

### Project Size
- Files: ~N source files
- Tests: ~N test files
- Contributors: N
- Age: first commit YYYY-MM-DD

### Areas to Explore Further
- [list 2-3 areas that need deeper reading]

### Conventions Noticed
- Testing: RSpec / Minitest / pytest
- Linting: RuboCop / ESLint / ...
- Commit style: conventional commits / freeform
```

## What NOT to Do

1. **Don't read everything.** You can't. Focus on entry points, architecture,
   and one data flow.
2. **Don't trust comments.** They rot. Trust tests and the code itself.
3. **Don't suggest changes during exploration.** Exploration is
   understanding-only. Save suggestions for after you understand.
4. **Don't assume based on framework convention.** A Rails app might have
   non-standard patterns. Read the actual code.
5. **Don't skip tests.** Reading test files for the core domain objects is
   often the fastest way to understand expected behavior.

## When to Stop

You have enough understanding when you can:
- Describe the project's purpose in 2-3 sentences
- Name the 3-5 key abstractions and their relationships
- Trace one complete data flow from entry to exit
- Identify where to look for a specific type of change

## Common Pitfalls

1. **Starting with details.** Don't read individual methods before
   understanding the high-level architecture.
2. **Reading sequentially.** Jump between entry points, tests, and config to
   build a triangulated understanding. Linear reading is slow.
3. **Assuming based on file names.** `UserService` might do billing, not user
   management. Read the first 10 lines of key files to confirm.
4. **Spending too long.** Phase 1-4 should take ~45 minutes total. Deeper
   understanding comes from making changes, not endless reading.
5. **Skipping the summary.** Writing a summary forces you to synthesize what
   you've learned. It also helps the user see what you (don't) understand.
