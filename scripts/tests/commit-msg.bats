#!/usr/bin/env bats
# Tests for scripts/hooks/commit-msg
#
# Validates that the hook enforces the SR&ED issue-driven commit conventions
# described in SR_ED_CONVENTIONS.md:
#
#   Rule 2: Branch names embed the issue number (<issue>-<slug>).
#   Rule 3: Commit subject format is `#<issue>: <summary>`.
#   Layer 1: The hook auto-prepends the prefix when missing (on issue branches)
#            and rejects subjects that reference a different issue.
#
# The hook is also expected to be a no-op during merge, rebase, and
# detached-HEAD states so it never blocks Git plumbing operations.

HOOK="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/hooks/commit-msg"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

setup() {
  TEST_DIR="$(mktemp -d)"
  cd "$TEST_DIR"
  git init -q
  git config user.email "test@example.com"
  git config user.name "Test User"
  # Use ';' as commentChar so '#NN:' subject lines survive git's cleanup pass
  # (mirrors what install-hooks.sh configures — see SR_ED_CONVENTIONS.md Layer 1).
  git config core.commentChar ";"
  git commit --allow-empty -q -m "initial"
  MSG_FILE="$TEST_DIR/COMMIT_EDITMSG"
}

teardown() {
  rm -rf "$TEST_DIR"
}

# Write a single-line commit message file.
write_msg() { printf '%s\n' "$1" > "$MSG_FILE"; }

# ---------------------------------------------------------------------------
# Rule 3 + Layer 1: issue branch, subject already correct
# ---------------------------------------------------------------------------

@test "issue branch: correct '#N: summary' subject passes unchanged" {
  git checkout -q -b 42-semantic-chunker-baseline
  write_msg "#42: add FixedSizeChunker baseline at 512/64"

  run bash "$HOOK" "$MSG_FILE"

  [ "$status" -eq 0 ]
  [ "$(cat "$MSG_FILE")" = "#42: add FixedSizeChunker baseline at 512/64" ]
}

# ---------------------------------------------------------------------------
# Layer 1: auto-prepend when subject lacks the '#N: ' prefix
# ---------------------------------------------------------------------------

@test "issue branch: subject without '#N: ' prefix gets it auto-prepended" {
  git checkout -q -b 42-semantic-chunker-baseline
  write_msg "add FixedSizeChunker baseline at 512/64"

  run bash "$HOOK" "$MSG_FILE"

  [ "$status" -eq 0 ]
  [ "$(cat "$MSG_FILE")" = "#42: add FixedSizeChunker baseline at 512/64" ]
}

@test "issue branch: auto-prepend message is printed to stderr" {
  git checkout -q -b 42-semantic-chunker-baseline
  write_msg "add FixedSizeChunker baseline at 512/64"

  run bash "$HOOK" "$MSG_FILE"

  [[ "$output" == *"auto-prepended"* ]]
}

# ---------------------------------------------------------------------------
# Layer 1: reject subject that references a different issue number
# ---------------------------------------------------------------------------

@test "issue branch: subject referencing a different issue number causes error" {
  git checkout -q -b 42-semantic-chunker-baseline
  write_msg "#99: unrelated work"

  run bash "$HOOK" "$MSG_FILE"

  [ "$status" -eq 1 ]
  [[ "$output" == *"#99"* ]]
  [[ "$output" == *"#42"* ]]
}

@test "issue branch: mismatch error message mentions the branch name" {
  git checkout -q -b 42-semantic-chunker-baseline
  write_msg "#99: unrelated work"

  run bash "$HOOK" "$MSG_FILE"

  [[ "$output" == *"42-semantic-chunker-baseline"* ]]
}

# ---------------------------------------------------------------------------
# Non-issue branch: subject must already carry '#N: ' prefix
# ---------------------------------------------------------------------------

@test "non-issue branch: subject with '#N: ' prefix passes" {
  # Branch 'main' has no issue number embedded.
  write_msg "#42: hotfix on main branch"

  run bash "$HOOK" "$MSG_FILE"

  [ "$status" -eq 0 ]
}

@test "non-issue branch: subject without '#N: ' prefix causes error" {
  write_msg "add feature without an issue reference"

  run bash "$HOOK" "$MSG_FILE"

  [ "$status" -eq 1 ]
  [[ "$output" == *"SR_ED_CONVENTIONS.md"* ]]
}

@test "non-issue branch: error message mentions the branch name" {
  local branch
  branch=$(git symbolic-ref --short HEAD)
  write_msg "fix things"

  run bash "$HOOK" "$MSG_FILE"

  [[ "$output" == *"$branch"* ]]
}

# ---------------------------------------------------------------------------
# Skip conditions: merge, rebase, detached HEAD
# ---------------------------------------------------------------------------

@test "hook is skipped during a merge (MERGE_HEAD present)" {
  touch "$TEST_DIR/.git/MERGE_HEAD"
  write_msg "Merge branch 'feature' into main"

  run bash "$HOOK" "$MSG_FILE"

  [ "$status" -eq 0 ]
}

@test "hook is skipped during an interactive rebase (rebase-merge dir)" {
  mkdir -p "$TEST_DIR/.git/rebase-merge"
  write_msg "fixup: tidy up a comment"

  run bash "$HOOK" "$MSG_FILE"

  [ "$status" -eq 0 ]
}

@test "hook is skipped during git-am / rebase-apply" {
  mkdir -p "$TEST_DIR/.git/rebase-apply"
  write_msg "applied patch from mailing list"

  run bash "$HOOK" "$MSG_FILE"

  [ "$status" -eq 0 ]
}

@test "hook is skipped when HEAD is detached" {
  git checkout -q --detach HEAD
  write_msg "detached-head work"

  run bash "$HOOK" "$MSG_FILE"

  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Edge cases
# ---------------------------------------------------------------------------

@test "issue branch: leading blank lines are ignored; real subject is prepended" {
  git checkout -q -b 42-semantic-chunker-baseline
  # Git prepends blank lines before the real subject in some editor workflows.
  printf '\n\nadd FixedSizeChunker\n' > "$MSG_FILE"

  run bash "$HOOK" "$MSG_FILE"

  [ "$status" -eq 0 ]
  grep -q "^#42: add FixedSizeChunker" "$MSG_FILE"
}

@test "issue branch: multi-digit issue number is handled correctly" {
  git checkout -q -b 123-big-feature-investigation
  write_msg "#123: implement big feature"

  run bash "$HOOK" "$MSG_FILE"

  [ "$status" -eq 0 ]
  [ "$(cat "$MSG_FILE")" = "#123: implement big feature" ]
}

@test "issue branch: multi-digit issue auto-prepend works" {
  git checkout -q -b 123-big-feature-investigation
  write_msg "implement big feature"

  run bash "$HOOK" "$MSG_FILE"

  [ "$status" -eq 0 ]
  [ "$(cat "$MSG_FILE")" = "#123: implement big feature" ]
}

@test "subject '#42: ...' survives when core.commentChar is ';'" {
  # install-hooks.sh sets core.commentChar=';' so '#NN:' lines are not
  # stripped by git's cleanup pass.  Verify the hook honours that setting.
  git checkout -q -b 42-semantic-chunker-baseline
  git config core.commentChar ";"
  write_msg "#42: subject that starts with hash"

  run bash "$HOOK" "$MSG_FILE"

  [ "$status" -eq 0 ]
  [ "$(cat "$MSG_FILE")" = "#42: subject that starts with hash" ]
}

@test "empty message file (all blank lines) exits cleanly" {
  git checkout -q -b 42-semantic-chunker-baseline
  printf '\n\n\n' > "$MSG_FILE"

  run bash "$HOOK" "$MSG_FILE"

  [ "$status" -eq 0 ]
}
