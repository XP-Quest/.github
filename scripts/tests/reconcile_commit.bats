#!/usr/bin/env bats
# Tests for scripts/reconcile_commit.sh
#
# Validates argument parsing, SHA resolution, dry-run output, and the
# already-reconciled guard described in SR_ED_CONVENTIONS.md "Layer 3 procedure".
#
# Most tests use --dry-run to avoid calling the real GitHub CLI or modifying
# the shared journal/.reconciled file.  The "already reconciled" test
# temporarily appends a test SHA to the real reconciled file and removes it
# in teardown to keep the audit log clean.

SCRIPT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/reconcile_commit.sh"
REAL_RECONCILED="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)/journal/.reconciled"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

setup() {
  TEST_DIR="$(mktemp -d)"

  # Create a temporary git repo with a commit we can reference by SHA.
  REPO="$TEST_DIR/testrepo"
  git init -q "$REPO"
  git -C "$REPO" config user.email "test@example.com"
  git -C "$REPO" config user.name "Test User"
  git -C "$REPO" remote add origin "https://github.com/XP-Quest/testrepo"
  git -C "$REPO" commit --allow-empty -q -m "test commit for reconcile tests"

  TEST_SHA=$(git -C "$REPO" rev-parse HEAD)
  TEST_SHORT_SHA=$(git -C "$REPO" rev-parse --short HEAD)

  # Track any SHA we append to the real reconciled file so teardown can clean up.
  ADDED_SHA=""
}

teardown() {
  # Remove any test SHA appended to the real reconciled file during tests.
  if [[ -n "$ADDED_SHA" && -f "$REAL_RECONCILED" ]]; then
    # Remove the line beginning with the test SHA.
    sed -i "/^${ADDED_SHA}/d" "$REAL_RECONCILED"
  fi
  rm -rf "$TEST_DIR"
}

# ---------------------------------------------------------------------------
# Argument validation
# ---------------------------------------------------------------------------

@test "no arguments: exits with status 1 and prints usage" {
  cd "$REPO"
  run bash "$SCRIPT"

  [ "$status" -eq 1 ]
  [[ "$output" == *"Usage"* ]]
}

@test "only SHA provided (missing issue): exits with status 1" {
  cd "$REPO"
  run bash "$SCRIPT" "$TEST_SHA"

  [ "$status" -eq 1 ]
  [[ "$output" == *"Usage"* ]]
}

@test "non-integer issue number exits with status 1" {
  cd "$REPO"
  run bash "$SCRIPT" "$TEST_SHA" "abc"

  [ "$status" -eq 1 ]
  [[ "$output" == *"positive integer"* ]]
}

@test "issue number with non-digit characters is rejected" {
  cd "$REPO"
  run bash "$SCRIPT" "$TEST_SHA" "42abc"

  [ "$status" -eq 1 ]
}

# ---------------------------------------------------------------------------
# SHA validation
# ---------------------------------------------------------------------------

@test "invalid (nonexistent) SHA exits with status 1" {
  cd "$REPO"
  run bash "$SCRIPT" "deadbeef000000000000000000000000000000ab" "42" \
    --repo XP-Quest/testrepo --message "test"

  [ "$status" -eq 1 ]
  [[ "$output" == *"not a valid commit"* ]]
}

@test "invalid SHA error message suggests running from inside the repo" {
  cd "$REPO"
  run bash "$SCRIPT" "000000000000" "42" \
    --repo XP-Quest/testrepo --message "test"

  [[ "$output" == *"inside the repo"* ]]
}

# ---------------------------------------------------------------------------
# --help
# ---------------------------------------------------------------------------

@test "--help exits with status 0" {
  cd "$REPO"
  run bash "$SCRIPT" --help

  [ "$status" -eq 0 ]
}

@test "-h exits with status 0" {
  cd "$REPO"
  run bash "$SCRIPT" -h

  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# --dry-run mode
# ---------------------------------------------------------------------------

@test "--dry-run: exits 0 without writing to .reconciled" {
  cd "$REPO"
  local before_lines
  before_lines=$(wc -l < "$REAL_RECONCILED")

  run bash "$SCRIPT" "$TEST_SHA" "42" \
    --repo XP-Quest/testrepo --message "test body" --dry-run

  [ "$status" -eq 0 ]
  local after_lines
  after_lines=$(wc -l < "$REAL_RECONCILED")
  [ "$before_lines" -eq "$after_lines" ]
}

@test "--dry-run: output includes the target repo and issue" {
  cd "$REPO"
  run bash "$SCRIPT" "$TEST_SHA" "42" \
    --repo XP-Quest/testrepo --message "test body" --dry-run

  [[ "$output" == *"XP-Quest/testrepo"* ]]
  [[ "$output" == *"#42"* ]]
}

@test "--dry-run: output includes the short SHA" {
  cd "$REPO"
  run bash "$SCRIPT" "$TEST_SHA" "42" \
    --repo XP-Quest/testrepo --message "test body" --dry-run

  [[ "$output" == *"$TEST_SHORT_SHA"* ]]
}

@test "--dry-run: output includes the comment body" {
  cd "$REPO"
  run bash "$SCRIPT" "$TEST_SHA" "42" \
    --repo XP-Quest/testrepo --message "my reconcile comment" --dry-run

  [[ "$output" == *"my reconcile comment"* ]]
}

@test "--dry-run: labels output as dry-run" {
  cd "$REPO"
  run bash "$SCRIPT" "$TEST_SHA" "42" \
    --repo XP-Quest/testrepo --message "body" --dry-run

  [[ "$output" == *"dry-run"* ]]
}

# ---------------------------------------------------------------------------
# Repo derivation from git remote
# ---------------------------------------------------------------------------

@test "repo is derived from origin remote URL when --repo is omitted" {
  cd "$REPO"
  run bash "$SCRIPT" "$TEST_SHA" "42" --message "body" --dry-run

  [[ "$output" == *"XP-Quest/testrepo"* ]]
}

@test "missing origin remote and no --repo exits with status 1" {
  # Create a repo with no origin configured.
  local bare="$TEST_DIR/bare-repo"
  git init -q "$bare"
  git -C "$bare" config user.email "test@example.com"
  git -C "$bare" config user.name "Test User"
  git -C "$bare" commit --allow-empty -q -m "bare commit"
  local bare_sha
  bare_sha=$(git -C "$bare" rev-parse HEAD)

  cd "$bare"
  run bash "$SCRIPT" "$bare_sha" "42" --message "body"

  [ "$status" -eq 1 ]
  [[ "$output" == *"origin"* ]]
}

# ---------------------------------------------------------------------------
# Already-reconciled guard (Layer 3 skip list)
# ---------------------------------------------------------------------------

@test "already-reconciled SHA exits 0 with informational note" {
  cd "$REPO"
  # The script stores the full 40-char SHA in .reconciled (SHORT_SHA="$SHA"
  # after git rev-parse, which returns the full SHA).
  echo "$TEST_SHA  reconciled to XP-Quest/testrepo#42 on 2026-01-15" \
    >> "$REAL_RECONCILED"
  ADDED_SHA="$TEST_SHA"

  run bash "$SCRIPT" "$TEST_SHA" "42" \
    --repo XP-Quest/testrepo --message "body"

  [ "$status" -eq 0 ]
  [[ "$output" == *"already"* ]]
}

@test "already-reconciled SHA does not post a new comment (exits before gh call)" {
  cd "$REPO"
  echo "$TEST_SHA  reconciled to XP-Quest/testrepo#42 on 2026-01-15" \
    >> "$REAL_RECONCILED"
  ADDED_SHA="$TEST_SHA"

  # If the script tried to call gh, it would fail (no real issue exists).
  # The test passes only because the script exits before reaching the gh call.
  run bash "$SCRIPT" "$TEST_SHA" "42" \
    --repo XP-Quest/testrepo --message "body"

  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Unknown option
# ---------------------------------------------------------------------------

@test "unknown option exits with status 1" {
  cd "$REPO"
  run bash "$SCRIPT" "$TEST_SHA" "42" --unknown-flag

  [ "$status" -eq 1 ]
}
