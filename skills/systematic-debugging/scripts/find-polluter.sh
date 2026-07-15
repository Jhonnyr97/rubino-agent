#!/usr/bin/env bash
# Bisection script to find which test creates unwanted files/state
#
# Usage: ./find-polluter.sh <pollution_check> <test_pattern>
# Example: ./find-polluter.sh '.git' '*_spec.rb'
#
# Runs tests one-by-one, stops at first polluter.

set -e

if [ $# -ne 2 ]; then
  echo "Usage: $0 <pollution_check> <test_pattern>"
  echo "Example: $0 '.git' '*_spec.rb'"
  exit 1
fi

POLLUTION_CHECK="$1"
TEST_PATTERN="$2"

echo "Searching for test that creates: $POLLUTION_CHECK"
echo "Test pattern: $TEST_PATTERN"
echo ""

# Detect test runner
if command -v bundle &>/dev/null && [ -f Gemfile ]; then
  RUNNER="bundle exec rspec"
elif command -v rspec &>/dev/null; then
  RUNNER="rspec"
elif command -v npm &>/dev/null && [ -f package.json ]; then
  RUNNER="npm test --"
else
  echo "Error: Could not detect test runner (rspec, bundle, or npm)"
  exit 1
fi

# Normalize an unanchored pattern so it matches at any depth. `find -path`
# compares against paths beginning with "./", so a bare glob like '*_spec.rb'
# would match zero files. Prefix "*/" unless the pattern is already anchored
# or wildcard-led.
case "$TEST_PATTERN" in
  /*|./*|\**|\?*|\[*) ;;            # already anchored or wildcard-led
  *) TEST_PATTERN="*/$TEST_PATTERN" ;;
esac

# Get list of test files
TEST_FILES=$(find . -path "$TEST_PATTERN" | sort)

if [ -z "$TEST_FILES" ]; then
  echo "Error: no test files matched pattern: $TEST_PATTERN"
  exit 1
fi

TOTAL=$(echo "$TEST_FILES" | wc -l | tr -d ' ')

echo "Found $TOTAL test files"
echo "Using runner: $RUNNER"
echo ""

COUNT=0
for TEST_FILE in $TEST_FILES; do
  COUNT=$((COUNT + 1))

  # Skip if pollution already exists
  if [ -e "$POLLUTION_CHECK" ]; then
    echo "Pollution already exists before test $COUNT/$TOTAL"
    echo "  Skipping: $TEST_FILE"
    continue
  fi

  echo "[$COUNT/$TOTAL] Testing: $TEST_FILE"

  # Run the test
  $RUNNER "$TEST_FILE" > /dev/null 2>&1 || true

  # Check if pollution appeared
  if [ -e "$POLLUTION_CHECK" ]; then
    echo ""
    echo "FOUND POLLUTER!"
    echo "  Test: $TEST_FILE"
    echo "  Created: $POLLUTION_CHECK"
    echo ""
    echo "Pollution details:"
    ls -la "$POLLUTION_CHECK"
    echo ""
    echo "To investigate:"
    echo "  $RUNNER $TEST_FILE  # Run just this test"
    echo "  cat $TEST_FILE      # Review test code"
    exit 1
  fi
done

echo ""
echo "No polluter found — all tests clean!"
exit 0
