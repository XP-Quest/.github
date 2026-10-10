#!/usr/bin/env bats
# Tests for scripts/xpq-branch-guard.sh
#
# The guard is a PreToolUse hook: it reads the hook JSON on stdin and prints a deny
# decision to block a Write/Edit, or prints nothing to allow it. It only acts for
# sessions whose working directory is under ~/xpquest.

GUARD="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/xpq-branch-guard.sh"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

setup() {
  export HOME="$BATS_TEST_TMPDIR/home"
  WORKSPACE="$HOME/xpquest"
  REPO="$WORKSPACE/repo"
  mkdir -p "$WORKSPACE" "$BATS_TEST_TMPDIR/elsewhere"
  git init -q -b main "$REPO"
  git -C "$REPO" config user.email "test@example.com"
  git -C "$REPO" config user.name "Test User"
  git -C "$REPO" commit -q --allow-empty -m "init"
}

# guard <file_path> [cwd]: feed the hook the JSON a Write/Edit call would send, with the
# hook process running in <cwd> (default: the workspace).
guard() {
  local payload
  payload=$(python3 -c 'import json, sys; print(json.dumps({"tool_input": {"file_path": sys.argv[1]}}))' "$1")
  cd "${2:-$WORKSPACE}"
  run bash "$GUARD" <<< "$payload"
}

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

@test "denies an edit on main in a repo under ~/xpquest" {
  guard "$REPO/file.txt"

  [ "$status" -eq 0 ]
  [[ "$output" == *'"permissionDecision":"deny"'* ]]
  [[ "$output" == *"main"* ]]
}

@test "allows an edit on an issue branch" {
  git -C "$REPO" switch -q -c 42-some-work

  guard "$REPO/file.txt"

  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "allows an edit to a file outside any git repo" {
  guard "$WORKSPACE/notes.md"

  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "does nothing for a session outside ~/xpquest" {
  guard "$REPO/file.txt" "$BATS_TEST_TMPDIR/elsewhere"

  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
