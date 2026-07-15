---
name: systematic-debugging
description: "Use when you hit any bug, error, test failure, crash, or unexpected behavior and are tempted to patch the symptom — enforces reproduce → isolate → root-cause before any fix."
category: "Debugging"
---

# Systematic Debugging

## Overview

Random fixes waste time and create new bugs. Quick patches mask underlying
issues.

**Core principle:** ALWAYS find root cause before attempting fixes. Symptom
fixes are failure.

## When to use

- You hit a bug, error, test failure, crash, or unexpected behavior
- You're tempted to patch the symptom (null check, retry, catch) without
  knowing why it happens
- A fix you tried didn't hold, or created a new problem

## Don't use for

- An already-understood one-line typo — just fix it
- Feature work with no bug to chase
- A fix that is obvious and already verified against the failing case

## The Iron Law

```
NO FIXES WITHOUT ROOT CAUSE INVESTIGATION FIRST
```

If you haven't completed Phase 1, you cannot propose fixes. Period.

## The Four Phases

### Phase 1: Reproduce

Before touching any code, reproduce the bug.

- Get the exact error message and stack trace
- Find the minimal reproduction steps
- Identify the exact input that triggers it
- Verify the bug is consistent (not intermittent without reason)

**Deliverable:** A one-sentence statement of the bug: "When [input], [code]
produces [wrong output] instead of [expected output]."

**Do NOT proceed to Phase 2 until you have reproduced the bug.**

### Phase 2: Isolate

Narrow down the cause to the smallest possible scope.

- Trace the code path from input to error. For deep call chains, load
  `references/root-cause-tracing.md` for the full tracing methodology
- Add targeted logging or debug statements if needed
- Binary-search the problem space: comment out half the code, does it still
  fail?
- Identify the exact line or condition where behavior diverges from
  expectation
- If a test is creating unwanted files/state, use `scripts/find-polluter.sh`
  to bisect which test is the culprit

**Deliverable:** The exact file, line number, and condition that causes the
bug.

**Do NOT propose fixes yet.**

### Phase 3: Root Cause

Understand WHY the code behaves this way. This is the most important phase.

- Why does this line produce the wrong result?
- What assumption is being violated?
- Is this a logic error, a data issue, a timing problem, a missing edge
  case?
- Has this area changed recently? Check git blame

**Deliverable:** A statement of the form: "The bug is caused by [specific
condition/assumption], which results in [mechanism of failure]."

Common root cause categories:

| Category | Example |
|---|---|
| Missing edge case | Empty input not handled |
| Wrong assumption | Expected array, got nil |
| Race condition | Read before write completes |
| API contract change | Upstream changed response shape |
| Off-by-one | Loop bound error |
| Type confusion | String where number expected |

### Phase 4: Fix

Only now — with root cause understood — propose and apply the fix.

- Write the minimal change that addresses the root cause
- Add a regression test that fails before the fix and passes after
- Verify the original reproduction case is resolved
- Check for similar patterns elsewhere in the codebase
- Run existing tests to ensure nothing is broken
- Add defense-in-depth validation at every layer data passes through. Load
  `references/defense-in-depth.md` for the four-layer pattern (entry
  validation → business logic → environment guards → debug instrumentation)

**Deliverable:** The fix + a regression test.

## What NOT to do

| Anti-pattern | Why it fails |
|---|---|
| "Try adding a null check" | Treats symptom, not cause. Null came from somewhere. |
| "Let's rewrite this function" | Destroys evidence. Fix the bug, then refactor. |
| "It works on my machine" | Environment difference IS a bug category. Investigate it. |
| "Add a retry" | Masks race conditions and transient failures. |
| "Catch the exception" | Silencing errors hides root cause. |
| Stack Overflow copy-paste | Context matters. Their fix may not match your root cause. |

## When the bug is in someone else's code

- If it's a dependency: verify version, check their issue tracker, consider
  a workaround
- If it's a teammate's code: present findings as facts ("When X happens, Y
  at line Z produces W"), not accusations
- If it's a platform/OS issue: isolate the platform-specific behavior and
  document the constraint

## Verification checklist

Before declaring the bug fixed:

- [ ] Original reproduction case passes
- [ ] Regression test added and passing
- [ ] Related edge cases tested (not just the happy path)
- [ ] Existing test suite passes
- [ ] No similar patterns elsewhere that need the same fix
- [ ] Fix is minimal — addresses root cause without scope creep
