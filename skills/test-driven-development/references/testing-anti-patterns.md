# Testing Anti-Patterns

**Load this reference when:** writing or changing tests, adding mocks, or
tempted to add test-only methods to production code.

## Overview

Tests must verify real behavior, not mock behavior. Mocks are a means to
isolate, not the thing being tested.

**Core principle:** Test what the code does, not what the mocks do.

Following strict TDD prevents these anti-patterns.

## The Iron Laws

```
1. NEVER test mock behavior
2. NEVER add test-only methods to production classes
3. NEVER mock without understanding dependencies
```

## Anti-Pattern 1: Testing Mock Behavior

**The violation:**

```ruby
# ❌ BAD: Testing that the double exists
it "renders sidebar" do
  allow(Sidebar).to receive(:render).and_return("<nav>mock</nav>")
  result = Page.render
  expect(result).to include("mock")
end
```

**Why this is wrong:**
- You're verifying the double works, not that the component works
- Test passes when double is present, fails when it's not
- Tells you nothing about real behavior

**The fix:**

```ruby
# ✅ GOOD: Test real component or don't double it
it "renders sidebar" do
  result = Page.render  # Don't double Sidebar
  expect(result).to include('<nav class="sidebar">')
end

# OR if Sidebar must be doubled for isolation:
# Don't assert on the double — test Page's behavior with sidebar present
```

### Gate Function

```
BEFORE asserting on any doubled object:
Ask: "Am I testing real component behavior or just double existence?"
IF testing double existence: STOP - Delete the assertion or remove the double
Test real behavior instead
```

## Anti-Pattern 2: Test-Only Methods in Production

**The violation:**

```ruby
# ❌ BAD: reset! only used in tests
class Session
  def reset!
    @workspace&.destroy
    @state = nil
  end
end

# In tests
after { session.reset! }
```

**Why this is wrong:**
- Production class polluted with test-only code
- Dangerous if accidentally called in production
- Violates YAGNI and separation of concerns

**The fix:**

```ruby
# ✅ GOOD: Test utilities handle test cleanup
# Session has no reset! — it's stateless in production

# In spec/support/session_helpers.rb:
module SessionHelpers
  def cleanup_session(session)
    workspace = session.workspace_info
    WorkspaceManager.destroy(workspace.id) if workspace
  end
end

# In tests
after { cleanup_session(session) }
```

### Gate Function

```
BEFORE adding any method to production class:
Ask: "Is this only used by tests?"
IF yes: STOP - Don't add it. Put it in test utilities instead.
Ask: "Does this class own this resource's lifecycle?"
IF no: STOP - Wrong class for this method
```

## Anti-Pattern 3: Mocking Without Understanding

**The violation:**

```ruby
# ❌ BAD: Double breaks test logic
it "detects duplicate server" do
  # Double prevents config write that test depends on!
  allow(ToolCatalog).to receive(:discover!).and_return(nil)

  add_server(config)
  add_server(config)  # Should raise duplicate error — but won't!
end
```

**Why this is wrong:**
- Doubled method had side effect test depended on (writing config)
- Over-doubling "to be safe" breaks actual behavior
- Test passes for wrong reason or fails mysteriously

**The fix:**

```ruby
# ✅ GOOD: Double at correct level
it "detects duplicate server" do
  # Double the slow part, preserve behavior test needs
  allow(MCPServerManager).to receive(:start_server)  # Just slow startup

  add_server(config)  # Config written
  expect { add_server(config) }.to raise_error(DuplicateServerError)
end
```

### Gate Function

```
BEFORE doubling any method: STOP - Don't double yet

1. Ask: "What side effects does the real method have?"
2. Ask: "Does this test depend on any of those side effects?"
3. Ask: "Do I fully understand what this test needs?"

IF depends on side effects:
  Double at lower level (the actual slow/external operation)
  OR use test doubles that preserve necessary behavior
  NOT the high-level method the test depends on

IF unsure what test depends on:
  Run test with real implementation FIRST
  Observe what actually needs to happen
  THEN add minimal doubling at the right level

Red flags:
  - "I'll double this to be safe"
  - "This might be slow, better double it"
  - Doubling without understanding the dependency chain
```

## Anti-Pattern 4: Incomplete Doubles

**The violation:**

```ruby
# ❌ BAD: Partial double — only fields you think you need
let(:mock_response) do
  { status: "success", data: { user_id: "123", name: "Alice" } }
  # Missing: metadata that downstream code uses
end

# Later: breaks when code accesses response[:metadata][:request_id]
```

**Why this is wrong:**
- Partial doubles hide structural assumptions
- You only doubled fields you know about
- Downstream code may depend on fields you didn't include
- Silent failures — tests pass but integration fails

**The Iron Rule:** Double the COMPLETE data structure as it exists in reality,
not just fields your immediate test uses.

**The fix:**

```ruby
# ✅ GOOD: Mirror real API completeness
let(:mock_response) do
  {
    status: "success",
    data: { user_id: "123", name: "Alice" },
    metadata: { request_id: "req-789", timestamp: 1_234_567_890 }
  }
end
```

### Gate Function

```
BEFORE creating test doubles:
Check: "What fields does the real response contain?"
Actions:
  1. Examine actual API response from docs/examples
  2. Include ALL fields system might consume downstream
  3. Verify double matches real response schema completely

Critical: If you're creating a double, understand the ENTIRE structure.
Partial doubles fail silently when code depends on omitted fields.
If uncertain: Include all documented fields.
```

## Anti-Pattern 5: Tests as Afterthought

**The violation:**
```
✅ Implementation complete
❌ No tests written
"Ready for review"
```

**Why this is wrong:**
- Testing is part of implementation, not optional follow-up
- TDD would have caught this
- Can't claim complete without tests

**The fix:** TDD cycle: write failing test → implement to pass → refactor →
THEN claim complete.

## When Doubles Become Too Complex

**Warning signs:**
- Double setup longer than test logic
- Doubling everything to make test pass
- Doubles missing methods real components have
- Test breaks when you change the double

**Consider:** Integration tests with real components are often simpler than
complex doubles.

## TDD Prevents These Anti-Patterns

**Why TDD helps:**
1. **Write test first** → Forces you to think about what you're actually
   testing
2. **Watch it fail** → Confirms test tests real behavior, not doubles
3. **Minimal implementation** → No test-only methods creep in
4. **Real dependencies** → You see what the test actually needs before
   doubling

**If you're testing double behavior, you violated TDD** — you added doubles
without watching test fail against real code first.

## Quick Reference

| Anti-Pattern | Fix |
|---|---|
| Assert on doubled elements | Test real component or remove the double |
| Test-only methods in production | Move to test utilities |
| Double without understanding | Understand dependencies first, double minimally |
| Incomplete doubles | Mirror real API completely |
| Tests as afterthought | TDD — tests first |
| Over-complex doubles | Consider integration tests |

## Red Flags

- Assertion checks for doubled objects
- Methods only called in test files
- Double setup is more than 50% of test
- Test fails when you remove double
- Can't explain why double is needed
- Doubling "just to be safe"

## The Bottom Line

**Doubles/mocks are tools to isolate, not things to test.**

If TDD reveals you're testing double behavior, you've gone wrong. Fix: Test
real behavior or question why you're doubling at all.
