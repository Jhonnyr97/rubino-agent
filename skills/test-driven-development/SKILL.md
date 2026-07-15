---
name: test-driven-development
description: "Use when about to implement a new feature, fix a bug, or refactor and you want the discipline of a failing test before the code (RED-GREEN-REFACTOR)."
category: "Testing"
---

# Test-Driven Development (TDD)

## Overview

Write the test first. Watch it fail. Write minimal code to pass.

**Core principle:** If you didn't watch the test fail, you don't know if it
tests the right thing.

## When to use

- Implementing a new feature, method, or endpoint
- Fixing a bug (write the failing test that reproduces it first)
- Refactoring behavior you want to pin down before changing

## Don't use for

- Throwaway spikes / exploratory prototypes — validate the idea first, then
  test-drive the real rebuild
- Generated or boilerplate code with no logic to specify
- Exploring an unknown API before you know the shape of the solution

## The Iron Law

```
NO PRODUCTION CODE WITHOUT A FAILING TEST FIRST
```

Wrote implementation code ahead of its test this turn? Set it aside and don't
reuse it verbatim — write the failing test first, then reimplement.

**For that just-written, untested code:**
- Don't keep it as "reference"
- Don't "adapt" it into place while writing tests
- Don't paste it back verbatim
- Reimplement it fresh, driven by the test

Never delete the user's existing or committed code — this rule is only about
untested code you just wrote in this turn.

Implement fresh from tests. Period.

## RED-GREEN-REFACTOR

### RED — Write Failing Test

Write one minimal test showing what should happen.

Requirements:
- One behavior per test
- Clear, descriptive name
- Tests real behavior (not mocks unless unavoidable)
- Use the project's test framework (RSpec, pytest, Jest, etc.)

Good:

```
test "retries failed operation 3 times" do
  attempts = 0
  operation = -> {
    attempts += 1
    raise "fail" if attempts < 3
    "success"
  }

  result = retry_operation(operation)

  expect(result).to eq("success")
  expect(attempts).to eq(3)
end
```

Bad:

```
test "retry works" do
  mock = double
  allow(mock).to receive(:call).and_raise("fail")
  retry_operation(mock)
end
```

Vague name, tests mock not code.

### Verify RED — Watch It Fail

**MANDATORY. Never skip.**

Run the test and confirm:
- Test fails (not errors)
- Failure message is expected
- Fails because feature missing (not typos)

**Test passes?** You're testing existing behavior. Fix the test.
**Test errors?** Fix the error, re-run until it fails correctly.

### GREEN — Minimal Code

Write the simplest code to pass the test. Just enough.

Don't add features, don't refactor other code, don't "improve" beyond what
the test demands.

### Verify GREEN — Watch It Pass

**MANDATORY.**

Run the test. Confirm:
- Test passes
- Other tests still pass
- No new warnings or errors

**Test fails?** Fix code, not test.
**Other tests fail?** Fix now.

### REFACTOR — Clean Up

After green only:
- Remove duplication
- Improve names
- Extract helpers

Keep tests green. Don't add behavior.

### Repeat

Next failing test for next feature.

## Good Tests

| Quality | Good | Bad |
|---|---|---|
| **Minimal** | One thing. "and" in name? Split it | `test "validates email and domain"` |
| **Clear** | Name describes behavior | `test "test1"` |
| **Shows intent** | Demonstrates desired API | Obscures what code should do |

## Why Order Matters

**"I'll write tests after to verify it works"**

Tests written after code pass immediately. Passing immediately proves
nothing:
- Might test wrong thing
- Might test implementation, not behavior
- Might miss edge cases you forgot
- You never saw it catch the bug

Test-first forces you to see the test fail, proving it actually tests
something.

**"I already manually tested all the edge cases"**

Manual testing is ad-hoc:
- No record of what you tested
- Can't re-run when code changes
- Easy to forget cases under pressure

Automated tests are systematic. They run the same way every time.

## Bug Fix Workflow

Bug found? Write failing test reproducing it. Follow TDD cycle. Test proves
fix and prevents regression. Never fix bugs without a test.

## Testing Anti-Patterns

When adding mocks or test utilities, load `references/testing-anti-patterns.md`
to avoid common pitfalls:

- Testing mock behavior instead of real behavior
- Adding test-only methods to production classes
- Mocking without understanding dependencies
- Testing internal implementation details (test behavior, not code)
- Creating incomplete mocks/doubles that hide structural assumptions

## When Stuck

| Problem | Solution |
|---|---|
| Don't know how to test | Write wished-for API. Write assertion first. |
| Test too complicated | Design too complicated. Simplify interface. |
| Must mock everything | Code too coupled. Use dependency injection. |
| Test setup huge | Extract helpers. Still complex? Simplify design. |

## Verification Checklist

Before marking work complete:

- [ ] Every new function/method has a test
- [ ] Watched each test fail before implementing
- [ ] Each test failed for expected reason (feature missing, not typo)
- [ ] Wrote minimal code to pass each test
- [ ] All tests pass
- [ ] Tests use real code (mocks only if unavoidable)
- [ ] Edge cases and errors covered

## Final Rule

```
Production code → test exists and failed first
Otherwise → not TDD
```
