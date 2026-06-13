---
name: diagnose-missing-test-files
description: "When a user requests running tests at a path that doesn't exist (e.g., test/ vs spec/, wrong filename), systematically locate the actual test setup, files, and framework before assuming failure."
---

# Diagnose Missing Test Files

## When to apply
User asks to run tests at a specific path (e.g., `test/foo_test.rb`) and:
- The file doesn't exist
- RSpec/Minitest reports "0 examples" with no real failure output
- The error trace points to a load/config issue, not an assertion

## Step-by-step

1. **Verify the path exists.** Use `read` on the exact path the user gave. If `File not found`, don't assume a bug in source code yet — the test file itself may be missing or misnamed.

2. **List the project root** with a shell `ls -la` to see top-level layout. Look for `test/`, `spec/`, `tests/`, `*_test.rb`, `*_spec.rb`. Different Ruby conventions:
   - Rails default: `test/` (Minitest)
   - RSpec default: `spec/`

3. **Find the actual test directory** with a glob like `**/*_test.rb` or `**/*_spec.rb`.

4. **Check the test framework config:**
   - `.rspec` file → likely RSpec, look in `spec/`
   - `Rakefile` test task → indicates framework
   - `Gemfile` → check for `rspec` or `minitest`

5. **Compare user-stated paths to reality**:
   - User said `test/calculator_test.rb` but project has `spec/` and uses RSpec
   - User said `lib/calculator.rb` but project is something completely different

6. **Don't fabricate a fix.** If the requested files don't exist, report the mismatch to the user with evidence (file listings, framework config) rather than guessing at bugs in unrelated code.

## Common pitfalls
- "0 examples, 0 failures" is a LOAD error, not a passing test suite. The shell exit code is nonzero only because RSpec couldn't find/load anything.
- Don't read truncated stack traces as test failures — they may be about `load_file_handling_errors` from a missing file.
- The project name (e.g., `rubino-agent`) and directory structure are strong hints about what the codebase actually is.

## Report template
Tell the user:
1. The exact path requested and why it can't be loaded
2. The actual project structure (directories, framework, config files found)
3. The likely mismatch (e.g., `test/` vs `spec/`, wrong filename, wrong project entirely)
4. Ask for clarification before changing source code
