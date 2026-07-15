# Root Cause Tracing

## Overview

Bugs often manifest deep in the call stack (git init in wrong directory, file
created in wrong location, database opened with wrong path). Your instinct is
to fix where the error appears, but that's treating a symptom.

**Core principle:** Trace backward through the call chain until you find the
original trigger, then fix at the source.

## When to Use

- Error happens deep in execution (not at entry point)
- Stack trace shows long call chain
- Unclear where invalid data originated
- Need to find which test/code triggers the problem

## The Tracing Process

### 1. Observe the Symptom

```
Error: git init failed in ~/project/packages/core
```

### 2. Find Immediate Cause

What code directly causes this?

```ruby
system("git", "init", chdir: project_dir)
```

### 3. Ask: What Called This?

```
WorktreeManager.create_workspace(project_dir, session_id)
  → called by Session#initialize_workspace
    → called by Session.create
      → called by test at Project.create
```

### 4. Keep Tracing Up

What value was passed?
- `project_dir = ""` (empty string!)
- Empty string as `chdir` resolves to `Dir.pwd`
- That's the source code directory!

### 5. Find Original Trigger

Where did empty string come from?

```ruby
context = setup_core_test  # Returns { temp_dir: "" }
Project.create("name", context[:temp_dir])  # Accessed before before block!
```

## Adding Stack Traces

When you can't trace manually, add instrumentation:

```ruby
# Before the problematic operation
def git_init(directory)
  $stderr.puts "DEBUG git init: directory=#{directory.inspect} " \
               "pwd=#{Dir.pwd.inspect} " \
               "caller=#{caller.first(5).join("\n  ")}"
  system("git", "init", chdir: directory)
end
```

**Critical:** Use `$stderr.puts` in tests (not logger — may be suppressed).

**Run and capture:**
```bash
bundle exec rspec 2>&1 | grep 'DEBUG git init'
```

## Finding Which Test Causes Pollution

If something appears during tests but you don't know which test, use the
`find-polluter.sh` script in `scripts/`:

```bash
./scripts/find-polluter.sh '.git' '*_spec.rb'
```

Runs tests one-by-one, stops at first polluter.

## Real Example: Empty project_dir

**Symptom:** `.git` created in source code directory

**Trace chain:**
1. `git init` runs in `Dir.pwd` ← empty chdir parameter
2. WorktreeManager called with empty project_dir
3. Session.create passed empty string
4. Test accessed `context[:temp_dir]` before `before` block
5. `setup_core_test` returns `{ temp_dir: "" }` initially

**Root cause:** Top-level variable initialization accessing empty value

**Fix:** Made temp_dir a method that raises if accessed before setup

**Also added defense-in-depth:**
- Layer 1: `Project.create` validates directory not empty
- Layer 2: `WorkspaceManager` validates not empty
- Layer 3: Environment guard refuses git init outside temp dir in tests
- Layer 4: Stack trace logging before git init

## Key Principle

```
Found immediate cause
    ↓
Can trace one level up?
    ├── YES → Trace backwards → Is this the source?
    │                              ├── NO → keep going
    │                              └── YES → Fix at source
    └── NO  → NEVER fix just the symptom
```

**NEVER fix just where the error appears.** Trace back to find the original
trigger.

## Stack Trace Tips

- **In tests:** Use `$stderr.puts`, not logger — logger may be suppressed
- **Before operation:** Log before the dangerous operation, not after it
  fails
- **Include context:** Directory, pwd, environment variables, timestamps
- **Capture stack:** `caller.first(10)` shows complete call chain
