#!/usr/bin/env bats
# Tests for scripts/install-hooks.sh
#
# Validates that the script correctly installs the commit-msg hook into a
# target git repository and configures core.commentChar so '#NN:' commit
# subjects survive git's cleanup pass (SR_ED_CONVENTIONS.md Layer 1).

SCRIPT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/install-hooks.sh"
HOOK_SRC="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/hooks/commit-msg"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

setup() {
  TEST_DIR="$(mktemp -d)"

  # Create a target git repo to install the hook into.
  REPO="$TEST_DIR/target-repo"
  git init -q "$REPO"
  git -C "$REPO" config user.email "test@example.com"
  git -C "$REPO" config user.name "Test User"
}

teardown() {
  rm -rf "$TEST_DIR"
}

# ---------------------------------------------------------------------------
# Successful installation
# ---------------------------------------------------------------------------

@test "install into valid repo creates commit-msg symlink in .git/hooks/" {
  run bash "$SCRIPT" "$REPO"

  [ "$status" -eq 0 ]
  [ -L "$REPO/.git/hooks/commit-msg" ]
}

@test "installed symlink points to the canonical hook source" {
  bash "$SCRIPT" "$REPO"

  [ "$(readlink "$REPO/.git/hooks/commit-msg")" = "$HOOK_SRC" ]
}

@test "hook source is made executable during install" {
  bash "$SCRIPT" "$REPO"

  [ -x "$HOOK_SRC" ]
}

@test "success output mentions the target repository path" {
  run bash "$SCRIPT" "$REPO"

  [[ "$output" == *"$REPO"* ]]
}

# ---------------------------------------------------------------------------
# core.commentChar configuration
# ---------------------------------------------------------------------------

@test "sets core.commentChar=';' when not previously configured" {
  # Ensure the setting is absent before install.
  git -C "$REPO" config --local --unset core.commentChar 2>/dev/null || true

  bash "$SCRIPT" "$REPO"

  [ "$(git -C "$REPO" config --local core.commentChar)" = ";" ]
}

@test "changes core.commentChar from '#' to ';'" {
  git -C "$REPO" config --local core.commentChar "#"

  bash "$SCRIPT" "$REPO"

  [ "$(git -C "$REPO" config --local core.commentChar)" = ";" ]
}

@test "leaves core.commentChar unchanged when already ';'" {
  git -C "$REPO" config --local core.commentChar ";"

  bash "$SCRIPT" "$REPO"

  [ "$(git -C "$REPO" config --local core.commentChar)" = ";" ]
}

@test "leaves non-default core.commentChar unchanged and prints a note" {
  git -C "$REPO" config --local core.commentChar "!"

  run bash "$SCRIPT" "$REPO"

  # The script should note the custom char and leave it as-is.
  [ "$(git -C "$REPO" config --local core.commentChar)" = "!" ]
  [[ "$output" == *"Note"* ]]
}

# ---------------------------------------------------------------------------
# Replacing existing hooks
# ---------------------------------------------------------------------------

@test "existing symlink at destination is replaced without error" {
  # Install once to create the symlink.
  bash "$SCRIPT" "$REPO"
  # Install again — should replace the symlink cleanly.
  run bash "$SCRIPT" "$REPO"

  [ "$status" -eq 0 ]
  [ -L "$REPO/.git/hooks/commit-msg" ]
}

@test "existing non-symlink hook is backed up before replacement" {
  # Put a real file at the hook destination to simulate a pre-existing hook.
  mkdir -p "$REPO/.git/hooks"
  echo "#!/usr/bin/env bash" > "$REPO/.git/hooks/commit-msg"
  chmod +x "$REPO/.git/hooks/commit-msg"

  run bash "$SCRIPT" "$REPO"

  [ "$status" -eq 0 ]
  # A backup file with a timestamp suffix should exist.
  local backup_count
  backup_count=$(ls "$REPO/.git/hooks/commit-msg.backup-"* 2>/dev/null | wc -l)
  [ "$backup_count" -ge 1 ]
}

@test "backup message is printed when a pre-existing hook is backed up" {
  mkdir -p "$REPO/.git/hooks"
  echo "#!/usr/bin/env bash" > "$REPO/.git/hooks/commit-msg"
  chmod +x "$REPO/.git/hooks/commit-msg"

  run bash "$SCRIPT" "$REPO"

  [[ "$output" == *"backup"* ]]
}

# ---------------------------------------------------------------------------
# Error cases
# ---------------------------------------------------------------------------

@test "non-git-repo target exits with status 1" {
  NOT_A_REPO="$TEST_DIR/plain-dir"
  mkdir "$NOT_A_REPO"

  run bash "$SCRIPT" "$NOT_A_REPO"

  [ "$status" -eq 1 ]
  [[ "$output" == *"not a git repository"* ]]
}

@test "default target is current working directory" {
  cd "$REPO"
  run bash "$SCRIPT"

  [ "$status" -eq 0 ]
  [ -L "$REPO/.git/hooks/commit-msg" ]
}
