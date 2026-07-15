# Defense-in-Depth Validation

## Overview

When you fix a bug caused by invalid data, adding validation at one place
feels sufficient. But that single check can be bypassed by different code
paths, refactoring, or test doubles.

**Core principle:** Validate at EVERY layer data passes through. Make the bug
structurally impossible.

## Why Multiple Layers

- Single validation: "We fixed the bug"
- Multiple layers: "We made the bug impossible"

Different layers catch different cases:
- Entry validation catches most bugs
- Business logic catches edge cases
- Environment guards prevent context-specific dangers
- Debug logging helps when other layers fail

## The Four Layers

### Layer 1: Entry Point Validation

**Purpose:** Reject obviously invalid input at API boundary

```ruby
def create_project(name, working_directory)
  if working_directory.nil? || working_directory.strip.empty?
    raise ArgumentError, "working_directory cannot be empty"
  end
  unless Dir.exist?(working_directory)
    raise ArgumentError, "working_directory does not exist: #{working_directory}"
  end
  # ... proceed
end
```

### Layer 2: Business Logic Validation

**Purpose:** Ensure data makes sense for this operation

```ruby
def initialize_workspace(project_dir, session_id)
  raise ArgumentError, "project_dir required" if project_dir.nil?
  # ... proceed
end
```

### Layer 3: Environment Guards

**Purpose:** Prevent dangerous operations in specific contexts

```ruby
def git_init(directory)
  # In tests, refuse git init outside temp directories
  if ENV["RUBINO_ENV"] == "test"
    normalized = File.expand_path(directory)
    tmpdir = File.expand_path(Dir.tmpdir)
    unless normalized.start_with?(tmpdir)
      raise "Refusing git init outside temp dir during tests: #{directory}"
    end
  end
  # ... proceed
end
```

### Layer 4: Debug Instrumentation

**Purpose:** Capture context for forensics

```ruby
def git_init(directory)
  $stderr.puts "About to git init: directory=#{directory.inspect} " \
               "pwd=#{Dir.pwd.inspect} caller=#{caller.first(3)}"
  # ... proceed
end
```

## Applying the Pattern

When you find a bug:

1. **Trace the data flow** — Where does bad value originate? Where is it
   used?
2. **Map all checkpoints** — List every point data passes through
3. **Add validation at each layer** — Entry, business, environment, debug
4. **Test each layer** — Try to bypass layer 1, verify layer 2 catches it

## Example from Session Bug

**Bug:** Empty `project_dir` caused `git init` in source code

**Data flow:**
1. Test setup → empty string
2. `Project.create("name", "")`
3. `WorkspaceManager.create_workspace("")`
4. `git init` runs in `Dir.pwd`

**Four layers added:**
- Layer 1: `Project.create` validates not empty, exists, writable
- Layer 2: `WorkspaceManager` validates project_dir not empty
- Layer 3: `WorktreeManager` refuses git init outside tmpdir in tests
- Layer 4: Stack trace logging before git init

**Result:** All tests passed, bug impossible to reproduce.

## Key Insight

All four layers were necessary. During testing, each layer caught bugs the
others missed:
- Different code paths bypassed entry validation
- Test doubles bypassed business logic checks
- Edge cases on different platforms needed environment guards
- Debug logging identified structural misuse

**Don't stop at one validation point.** Add checks at every layer.
