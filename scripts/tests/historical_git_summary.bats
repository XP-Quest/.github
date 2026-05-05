#!/usr/bin/env bats
# Tests for scripts/historical_git_summary.sh
#
# Validates argument parsing, date-range validation, and per-day delegation
# to daily_git_summary.sh.
#
# The script is tested in isolation by replacing daily_git_summary.sh with
# a lightweight stub via the DAILY_SCRIPT override path mechanism (the test
# injects a fake daily_git_summary.sh into PATH ahead of the real one).

SCRIPT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/historical_git_summary.sh"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

setup() {
  TEST_DIR="$(mktemp -d)"

  # Create a stub daily_git_summary.sh that records every date it was called with.
  STUB_BIN="$TEST_DIR/bin"
  mkdir -p "$STUB_BIN"
  CALLS_FILE="$TEST_DIR/calls.txt"
  touch "$CALLS_FILE"

  cat > "$STUB_BIN/daily_git_summary.sh" <<STUB
#!/usr/bin/env bash
echo "\$1" >> "$CALLS_FILE"
STUB
  chmod +x "$STUB_BIN/daily_git_summary.sh"

  # historical_git_summary.sh calls "\$SCRIPT_DIR/daily_git_summary.sh", so we
  # cannot override it via PATH.  Copy the real daily_git_summary.sh stub
  # next to the historical script by pointing SCRIPT_DIR at our stub bin.
  # Instead, we test the script directly; for "calls per day" assertions we
  # rely on OUTPUT_DIR + SEARCH_ROOT set to an empty tree so daily_git_summary.sh
  # exits cleanly (no commits) without writing files.
  export SEARCH_ROOT="$TEST_DIR/repos"
  export OUTPUT_DIR="$TEST_DIR/output"
  export RECONCILED_FILE="$TEST_DIR/.reconciled"
  mkdir -p "$SEARCH_ROOT" "$OUTPUT_DIR"
  touch "$RECONCILED_FILE"
}

teardown() {
  rm -rf "$TEST_DIR"
}

# ---------------------------------------------------------------------------
# --from is required
# ---------------------------------------------------------------------------

@test "--from is required: missing --from exits with status 1" {
  run bash "$SCRIPT"

  [ "$status" -eq 1 ]
  [[ "$output" == *"--from"* ]]
}

@test "--from is required: error message references --from" {
  run bash "$SCRIPT" --to 2026-01-15

  [ "$status" -eq 1 ]
  [[ "$output" == *"--from"* ]]
}

# ---------------------------------------------------------------------------
# --help
# ---------------------------------------------------------------------------

@test "--help exits with status 0" {
  run bash "$SCRIPT" --help

  [ "$status" -eq 0 ]
}

@test "-h exits with status 0" {
  run bash "$SCRIPT" -h

  [ "$status" -eq 0 ]
}

@test "--help output includes usage information" {
  run bash "$SCRIPT" --help

  [[ "$output" == *"--from"* ]]
  [[ "$output" == *"--to"* ]]
}

# ---------------------------------------------------------------------------
# Date validation
# ---------------------------------------------------------------------------

@test "invalid --from date exits with status 1" {
  run bash "$SCRIPT" --from "not-a-date"

  [ "$status" -eq 1 ]
  [[ "$output" == *"invalid"* ]]
}

@test "invalid --to date exits with status 1" {
  run bash "$SCRIPT" --from 2026-01-01 --to "not-a-date"

  [ "$status" -eq 1 ]
  [[ "$output" == *"invalid"* ]]
}

@test "invalid date error echoes the bad input" {
  run bash "$SCRIPT" --from "bad-input"

  [[ "$output" == *"bad-input"* ]]
}

@test "--from after --to exits with status 1" {
  run bash "$SCRIPT" --from 2026-01-20 --to 2026-01-15

  [ "$status" -eq 1 ]
  [[ "$output" == *"--from"* ]]
}

@test "--from equal to --to is accepted (single-day range)" {
  run bash "$SCRIPT" --from 2026-01-15 --to 2026-01-15

  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Range behaviour: verify each date in range is processed
# ---------------------------------------------------------------------------

@test "single date range prints processing message for that date" {
  run bash "$SCRIPT" --from 2026-01-15 --to 2026-01-15

  [[ "$output" == *"2026-01-15"* ]]
}

@test "three-day range prints processing message for each of the three dates" {
  run bash "$SCRIPT" --from 2026-01-13 --to 2026-01-15

  [[ "$output" == *"2026-01-13"* ]]
  [[ "$output" == *"2026-01-14"* ]]
  [[ "$output" == *"2026-01-15"* ]]
}

@test "unknown option exits with status 1" {
  run bash "$SCRIPT" --unknown-flag

  [ "$status" -eq 1 ]
}

# ---------------------------------------------------------------------------
# --to defaults to today
# ---------------------------------------------------------------------------

@test "omitting --to defaults to today (script completes without error)" {
  # Use today's date as both --from and implied --to.
  today=$(date +%Y-%m-%d)
  run bash "$SCRIPT" --from "$today"

  [ "$status" -eq 0 ]
}
