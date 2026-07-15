---
name: release
description: Use when generating changelogs, release notes, or version bumps — "generate changelog", "create release notes", "summarize changes since last release", "what changed on this branch?". Parses git history, groups by type, produces Keep a Changelog formatted output or user-facing release notes.
version: 1.0.0
license: MIT
category: "DevOps"
---

# Release — Changelogs & Release Notes

Generate structured changelogs and release notes from git commit history.
Produces well-organized, categorized output following the Keep a Changelog
convention. Handles both technical changelogs for developers and user-facing
release notes.

## When to use

- "generate a changelog" / "create release notes"
- "summarize changes since last release"
- "what changed on this branch?"
- Before creating a GitHub Release
- When updating CHANGELOG.md for a new version

## Don't use for

- Anything that isn't a changelog / release / version task
- A single uncommitted change with no history to summarize
- Repos with no git tags or commit history to draw from

## Step 1 — Determine the Scope

Identify what range of changes to include:

```bash
# List recent tags to find version boundaries
git tag --sort=-creatordate | head -10

# Get the last tag
LAST_TAG=$(git describe --tags --abbrev=0 2>/dev/null)
echo "Last tag: $LAST_TAG"
```

If no tags exist, ask the user for a date range or commit range.

## Step 2 — Collect Commits

```bash
# Commits since last tag
git log "$LAST_TAG"..HEAD --format="%h %s (%an, %ad)" --date=short --no-merges

# Or between two tags
git log v1.1.0..v1.2.0 --format="%h %s (%an, %ad)" --date=short --no-merges

# Or custom date range
git log --since="2 weeks ago" --format="%h %s (%an, %ad)" --date=short --no-merges
```

For each commit, extract:
- **Type** — from conventional commit prefix (`feat:`, `fix:`, `docs:`,
  `refactor:`, `chore:`, `security:`, `deprecate:`, `remove:`)
- **Scope** — from conventional commit scope if present
- **Description** — the commit message body
- **PR number** — from merge commit or commit body (`(#123)`)

## Step 3 — Categorize

Sort each commit into categories based on the commit message:

| Prefix | Category | Description |
|--------|----------|-------------|
| `feat:` | Added | New features or capabilities |
| `fix:` | Fixed | Bug fixes |
| `refactor:`, `perf:` | Changed | Changes to existing functionality |
| `docs:` | Changed | User-facing docs changes (skip internal) |
| `deprecate:` | Deprecated | Features to be removed |
| `remove:`, `breaking:`, `feat!:` | Removed / Breaking | Breaking changes |
| `security:` | Security | Vulnerability fixes |
| `chore:`, `ci:`, `build:` | Maintenance | Skip unless significant |

If commits lack conventional prefixes, read the diff to classify:

```bash
git show --stat <commit>
```

## Step 4 — Detect Breaking Changes

Scan for breaking change indicators:
- `feat!:` or `fix!:` prefix
- `BREAKING CHANGE:` in commit body
- Removed or changed public APIs, config keys, migrations

Breaking changes always go first in the changelog with a migration path.

## Step 5 — Write the Changelog

Format following Keep a Changelog:

```markdown
## [X.Y.Z] - YYYY-MM-DD

### Breaking Changes
- Change description and migration path (#PR)

### Added
- Feature description in user language (#PR)

### Changed
- What changed and why it matters (#PR)

### Fixed
- Bug description and what was corrected (#PR)
```

**Rules for writing entries:**
- Write from the user's perspective, not the developer's
- Start each item with a verb (Add, Fix, Update, Remove)
- Include PR or issue numbers when available
- Group related changes into a single entry
- Skip internal refactors unless they affect behavior
- Mention breaking changes prominently with upgrade guidance

## Step 6 — Output

- If `CHANGELOG.md` exists, read it first, then prepend the new entry below
  the header
- If this is for a GitHub Release, use `gh release create --notes-file ...`
- Always show the user the generated content before writing to a file
- If the user requests user-facing release notes, use a more narrative style
  with a "Highlights" section

## User-Facing Release Notes (Alternative Format)

When asked for user-facing notes:

```markdown
# What's New in vX.Y.Z

## Highlights

**Feature Name** — Brief description of impact.

**Another Highlight** — Brief description.

## Bug Fixes

- Fix description
- Fix description

## Full Changelog

See the [complete changelog](./CHANGELOG.md) for all details.
```

## Guidelines

- Always read the existing CHANGELOG.md format before generating a new entry
  to match the style
- Use semantic versioning: breaking changes = major, new features = minor,
  fixes = patch
- For conventional commits repos, leverage the prefixes for automatic
  categorization
- Skip trivial commits (typo fixes, whitespace changes) unless the user wants
  everything
- When in doubt about whether a change is user-facing, include it
- For monorepos, group changes by package or service
- Always include the date in ISO 8601 format (YYYY-MM-DD)

## Common Pitfalls

1. **Deriving version from commits instead of tags.** Tags are the source of
   truth for versions.
2. **Including internal-only changes.** CI config changes, refactors with no
   behavioral impact, and dev-only scripts don't belong in user changelogs.
3. **Listing every commit.** Group related commits into a single user-facing
   entry. A changelog is not a git log dump.
4. **Forgetting breaking changes.** Always scan `!` prefixes and `BREAKING
   CHANGE:` footers.
5. **Skipping the existing file read.** If `CHANGELOG.md` exists, read it
   first to match its format and precedents.

## Attribution

Adapted from the TerminalSkills `changelog-generator` skill (Apache 2.0) and
the `christophacham/agent-skills-library` release-notes skill (MIT).
