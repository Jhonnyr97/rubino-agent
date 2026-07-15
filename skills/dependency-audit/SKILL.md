---
name: dependency-audit
description: Use when auditing project dependencies — "audit dependencies", "check for vulnerabilities", "are my gems outdated?", "what can I remove?". Scans for security vulnerabilities, outdated packages, unused dependencies, and license issues. Supports Ruby (Bundler), Python (pip), Node (npm), and auto-detects project type.
version: 1.0.0
license: MIT
category: "Security"
---

# Dependency Audit

Systematic audit of project dependencies across four dimensions: security,
freshness, necessity, and licensing.

**Core principle:** Every dependency is a liability. Audit before adding new
ones; audit existing ones regularly.

## When to use

- "audit my dependencies" / "check for vulnerabilities"
- "are there outdated packages?"
- "what can I remove from Gemfile / package.json?"
- Before adding a new dependency
- As part of pre-release verification

## Don't use for

- A task that isn't about dependencies, security, or outdated packages
- A project with no lockfile or manifest to audit against

## Step 1 — Detect the Project

Auto-detect the package manager by checking for lock/config files:

```bash
# Priority order — first match wins
test -f Gemfile.lock && echo "bundler"
test -f package-lock.json && echo "npm"
test -f yarn.lock && echo "yarn"
test -f requirements.txt && echo "pip"
test -f Cargo.lock && echo "cargo"
test -f go.sum && echo "go"
```

## Step 2 — Security Scan

### Ruby (Bundler)

```bash
# Refresh the advisory DB, then check for known CVEs
bundle audit update 2>&1
bundle audit check 2>&1
# (standalone binary equivalent: bundle-audit check)

# If bundler-audit not installed
gem install bundler-audit 2>/dev/null
```

Priority levels: **Critical** (exploitable remotely) > **High** (data
exposure) > **Medium** (DoS, info leak) > **Low**.

### Node (npm)

```bash
# Built-in audit
npm audit --json 2>&1

# For severity filtering
npm audit --audit-level=high 2>&1
```

### Python (pip)

```bash
# pip-audit (installs if needed)
pip install pip-audit 2>/dev/null
pip-audit 2>&1

# Or safety
pip install safety 2>/dev/null
safety check 2>&1
```

## Step 3 — Freshness Check

### Ruby

```bash
bundle outdated --filter-patch 2>&1   # Only major/minor first
bundle outdated --groups 2>&1         # Full picture
```

### Node

```bash
npm outdated --json 2>&1
# or
npx npm-check-updates --format group 2>&1
```

### Python

```bash
pip list --outdated --format columns 2>&1
```

## Step 4 — Unused Dependency Detection

### Ruby

Scope the check to DIRECT dependencies only — the gems named in the `Gemfile`.
Iterating `bundle list` scans every resolved gem, including transitive
dependencies, and would flag essentially all of them as "unused" (massive
false positives). Parse the `Gemfile` instead:

```bash
# Only direct deps declared in the Gemfile
grep -oE "^\s*gem\s+['\"][^'\"]+['\"]" Gemfile 2>/dev/null \
  | grep -oE "['\"][^'\"]+['\"]" | tr -d "\"'" | while read -r gem; do
  if ! grep -rq "require.*['\"]$gem['\"]" lib/ app/ 2>/dev/null; then
    echo "POTENTIALLY UNUSED: $gem"
  fi
done
```

**Caveat:** unused-dependency detection is heuristic. A gem can be required
dynamically, autoloaded, used only in a Rake task, or required under a
different name than its gem name. Treat the output as candidates only — prefer
a dedicated tool where available and confirm manually before removing anything.

Or use a dedicated tool if available:

```bash
gem install bundler-leak 2>/dev/null
bundle leak check 2>&1
```

### Node

```bash
npx depcheck 2>&1
```

### Python

```bash
pip install pipdeptree 2>/dev/null
pipdeptree --warn silence | grep -E "^\s+"  # Look for leaves
```

## Step 5 — License Check

```bash
# Ruby
bundle exec license_finder 2>/dev/null || \
  gem install license_finder 2>/dev/null && bundle exec license_finder

# Node
npx license-checker --summary 2>&1

# Python
pip install pip-licenses 2>/dev/null
pip-licenses --summary 2>&1
```

Flag: copyleft licenses (GPL, AGPL) in proprietary projects; unlicensed
packages; incompatible license combinations.

## Step 6 — Before Adding a New Dependency

Before adding ANY new dependency, answer these questions:

1. **Does the existing stack solve this?** Check the standard library and
   existing dependencies first. Often they already do.
2. **How large is it?** Check the download size / bundle impact.
3. **Is it actively maintained?** Check last commit date, release frequency,
   open issues ratio.
4. **Does it have known vulnerabilities?** Run the security scan from Step 2
   on it.
5. **What's the license?** Must be compatible with the project.
6. **How many transitive dependencies does it pull?** A single gem can pull
   50+ transitive deps.

```bash
# Check gem stats
gem info <gem-name> 2>/dev/null

# Check npm package stats
npm view <package> 2>&1

# Check GitHub activity
gh repo view <owner>/<repo>
```

## Step 7 — Report Format

```markdown
## Dependency Audit Report — YYYY-MM-DD

### Project: <name>
### Package Manager: bundler / npm / pip

### Security
- **Critical:** # issues (must fix immediately)
- **High:** # issues (fix before next release)
- **Medium:** # issues (fix this sprint)
- **Low:** # issues (schedule)

### Outdated
- **Major:** # packages (breaking changes — plan migration)
- **Minor:** # packages (new features — update with tests)
- **Patch:** # packages (bug fixes — safe to update)

### Possibly Unused
- `<package>` — no imports found in lib/ or app/

### License Issues
- `<package>` — GPL-3.0 (incompatible with project's MIT)

### Recommendations
1. Fix Critical/High CVEs first [specific action]
2. Update patch-level packages [bundle update --patch]
3. Evaluate major upgrades [list with migration notes]
4. Remove confirmed unused packages [list]
```

## Common Pitfalls

1. **Silent audit failures.** Audit tools that error out (missing DB, network
   failure) should be reported, not skipped silently.
2. **Blindly updating everything.** Major version bumps need changelog review
   and migration testing.
3. **Trusting green audit output.** No CVEs does not mean no risk — unmaintained
   packages with zero CVEs are still a liability.
4. **Removing packages that ARE used.** A gem may be required dynamically
   (autoloaded, required in a Rake task). Always grep the codebase before
   removing.
5. **Ignoring transitive deps.** Your direct dependency's dependencies are
   your problem too. `bundle audit` already covers transitive deps; `npm audit`
   does too.

## Attribution

Methodology adapted from dependency audit best practices across Ruby, Node,
and Python ecosystems — bundler-audit, npm audit, pip-audit.
