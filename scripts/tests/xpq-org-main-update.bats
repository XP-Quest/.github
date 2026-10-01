#!/usr/bin/env bats
# Tests for scripts/xpq-org-main-update.sh
#
# A real bare "origin" and a clone on main stand in for XP-Quest/.github and
# ~/xpquest/.xpq-org-main. Permission checks assume a non-root user (root
# ignores write bits), so they are skipped under root.

SCRIPT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/xpq-org-main-update.sh"

setup() {
  TMP="$(mktemp -d)"
  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
  git init -q --bare -b main "$TMP/origin.git"
  git clone -q "$TMP/origin.git" "$TMP/work" 2>/dev/null
  mkdir -p "$TMP/work/scripts"
  echo v1 > "$TMP/work/scripts/tool.sh"
  git -C "$TMP/work" add -A && git -C "$TMP/work" commit -q -m v1 && git -C "$TMP/work" push -q origin main
  git clone -q "$TMP/origin.git" "$TMP/clone" 2>/dev/null
  CLONE="$TMP/clone"
}

teardown() {
  chmod -R u+w "$TMP" 2>/dev/null || true
  rm -rf "$TMP"
}

# push_change <content>: a new commit on origin/main touching scripts/tool.sh plus a new file.
push_change() {
  echo "$1" > "$TMP/work/scripts/tool.sh"
  echo new > "$TMP/work/scripts/added-$1.sh"
  git -C "$TMP/work" add -A && git -C "$TMP/work" commit -q -m "$1" && git -C "$TMP/work" push -q origin main
}

skip_if_root() {
  [[ "$(id -u)" -ne 0 ]] || skip "root ignores write permission bits"
}

@test "--lock blocks edits, new files, deletes and renames" {
  skip_if_root
  run "$SCRIPT" --lock "$CLONE"
  [ "$status" -eq 0 ]
  run bash -c "echo x > '$CLONE/scripts/tool.sh'"; [ "$status" -ne 0 ]
  run touch "$CLONE/scripts/new.sh";                [ "$status" -ne 0 ]
  run touch "$CLONE/new-at-root";                   [ "$status" -ne 0 ]
  run rm -f "$CLONE/scripts/tool.sh";               [ "$status" -ne 0 ]
  run mv "$CLONE/scripts/tool.sh" "$CLONE/scripts/x"; [ "$status" -ne 0 ]
  [ "$(cat "$CLONE/scripts/tool.sh")" = v1 ]
}

@test "--lock leaves .git writable" {
  skip_if_root
  "$SCRIPT" --lock "$CLONE"
  touch "$CLONE/.git/probe"
  git -C "$CLONE" fetch -q
}

@test "a plain git pull fails on a locked clone" {
  skip_if_root
  "$SCRIPT" --lock "$CLONE"
  push_change v2
  run git -C "$CLONE" pull --ff-only --quiet
  [ "$status" -ne 0 ]
}

@test "update fast-forwards a locked clone and relocks it" {
  skip_if_root
  "$SCRIPT" --lock "$CLONE"
  push_change v2
  run "$SCRIPT" "$CLONE"
  [ "$status" -eq 0 ]
  [ "$(cat "$CLONE/scripts/tool.sh")" = v2 ]
  [ -f "$CLONE/scripts/added-v2.sh" ]
  run touch "$CLONE/scripts/new.sh";             [ "$status" -ne 0 ]
  run bash -c "echo x > '$CLONE/scripts/added-v2.sh'"; [ "$status" -ne 0 ]
}

@test "update relocks even when the pull fails" {
  skip_if_root
  "$SCRIPT" --lock "$CLONE"
  git -C "$CLONE" remote set-url origin "$TMP/missing.git"
  run "$SCRIPT" "$CLONE"
  [ "$status" -eq 1 ]
  [[ "$output" == *"relocked"* ]]
  run touch "$CLONE/scripts/new.sh"; [ "$status" -ne 0 ]
}

@test "update preserves the executable bit" {
  skip_if_root
  chmod +x "$CLONE/scripts/tool.sh"
  "$SCRIPT" --lock "$CLONE"
  [ -x "$CLONE/scripts/tool.sh" ]
  "$SCRIPT" "$CLONE"
  [ -x "$CLONE/scripts/tool.sh" ]
}

@test "update works when the pull rewrites the updater itself" {
  skip_if_root
  cp "$SCRIPT" "$TMP/work/scripts/updater.sh"
  git -C "$TMP/work" add -A && git -C "$TMP/work" commit -q -m updater && git -C "$TMP/work" push -q origin main
  git -C "$CLONE" pull -q --ff-only
  "$SCRIPT" --lock "$CLONE"
  # The next commit rewrites the updater itself, as a real update of this script would.
  { echo '#!/usr/bin/env bash'; echo 'echo REPLACED; exit 0'; } > "$TMP/work/scripts/updater.sh"
  git -C "$TMP/work" add -A && git -C "$TMP/work" commit -q -m rewrite && git -C "$TMP/work" push -q origin main
  run bash "$CLONE/scripts/updater.sh" "$CLONE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Updated"* ]]
  [[ "$output" != *"REPLACED"* ]]
  run touch "$CLONE/scripts/new.sh"; [ "$status" -ne 0 ]
}

@test "refuses a clone that is not on main" {
  git -C "$CLONE" switch -q -c feature
  run "$SCRIPT" "$CLONE"
  [ "$status" -eq 2 ]
  [[ "$output" == *"not main"* ]]
}

@test "refuses a path that is not a git clone" {
  run "$SCRIPT" "$TMP"
  [ "$status" -eq 2 ]
}
