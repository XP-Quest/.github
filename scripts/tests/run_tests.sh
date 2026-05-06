#!/usr/bin/env bash
# Run the full SR&ED script test suite using bats.
#
# Usage:
#   scripts/tests/run_tests.sh [bats options] [test file(s)]
#
# Examples:
#   # Run all tests
#   scripts/tests/run_tests.sh
#
#   # Run only the commit-msg tests
#   scripts/tests/run_tests.sh scripts/tests/commit-msg.bats
#
#   # Run with verbose output
#   scripts/tests/run_tests.sh --verbose
set -euo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! command -v bats >/dev/null 2>&1; then
  echo "Error: bats is not installed." >&2
  echo "Install it with: sudo apt-get install bats-core" >&2
  echo "            or:  brew install bats-core" >&2
  echo "Note: bats-core >= 1.5.0 is required (for 'run !' negation syntax)." >&2
  exit 1
fi

# Separate bats flags from explicit test-file arguments.
bats_args=()
test_files=()
for arg in "$@"; do
  if [[ "$arg" == -* ]]; then
    bats_args+=("$arg")
  else
    test_files+=("$arg")
  fi
done

# Default to all .bats files in this directory.
if [[ ${#test_files[@]} -eq 0 ]]; then
  while IFS= read -r f; do
    test_files+=("$f")
  done < <(find "$TESTS_DIR" -maxdepth 1 -name '*.bats' | sort)
fi

exec bats "${bats_args[@]}" "${test_files[@]}"
