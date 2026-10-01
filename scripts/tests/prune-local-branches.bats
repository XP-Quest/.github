#!/usr/bin/env bats
# Tests for scripts/prune-local-branches.sh
#
# The script deletes local branches, so these tests pin down what it must NOT
# delete as carefully as what it must: main/dev, unmerged work, never-pushed
# branches, branches checked out in a worktree, a dirty current branch.
#
# Each test builds a real bare "origin" plus a clone under $ROOT, so git itself
# is the fixture; nothing is mocked.

SCRIPT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/prune-local-branches.sh"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

setup() {
  TMP="$(mktemp -d)"
  ROOT="$TMP/root"
  mkdir "$ROOT"
  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
}

teardown() {
  rm -rf "$TMP"
}

# make_repo <name> [with_dev=1]: bare origin + clone at $ROOT/<name>, on main
# (and dev, if with_dev). Leaves the clone checked out on its integration branch.
make_repo() {
  local name="$1" with_dev="${2:-1}"
  git init -q --bare -b main "$TMP/$name.git"
  git clone -q "$TMP/$name.git" "$ROOT/$name" 2>/dev/null
  cd "$ROOT/$name"
  git commit -q --allow-empty -m init
  git push -q origin main
  if [[ "$with_dev" -eq 1 ]]; then
    git switch -q -c dev
    git push -q -u origin dev
  fi
  cd - >/dev/null
}

# feature <repo> <branch> [base]: branch off base with one commit, pushed with -u.
feature() {
  cd "$ROOT/$1"
  git switch -q -c "$2" "${3:-dev}"
  git commit -q --allow-empty -m "$2 work"
  git push -q -u origin "$2"
  cd - >/dev/null
}

# merge_into <repo> <branch> <target>: what merging its PR does to origin/<target>.
merge_into() {
  cd "$ROOT/$1"
  git switch -q "$3"
  git merge -q --no-ff -m "merge $2" "$2"
  git push -q origin "$3"
  cd - >/dev/null
}

has_branch() {
  git -C "$ROOT/$1" rev-parse -q --verify "refs/heads/$2" >/dev/null
}

# A bare `! has_branch` cannot fail a bats test (errexit ignores `!`), so the
# negative check is its own function, whose non-zero return does.
no_branch() {
  if has_branch "$@"; then return 1; fi
}

# ---------------------------------------------------------------------------
# What it prunes
# ---------------------------------------------------------------------------

@test "deletes a branch merged to dev" {
  make_repo app
  feature app 5-thing
  merge_into app 5-thing dev
  run "$SCRIPT" --root "$ROOT"
  [ "$status" -eq 0 ]
  no_branch app 5-thing
  [[ "$output" == *"deleted 5-thing"* ]]
}

@test "deletes a trivial-fixes branch once merged; git switch brings it back" {
  make_repo app
  feature app 12-trivial-fixes
  merge_into app 12-trivial-fixes dev
  run "$SCRIPT" --root "$ROOT"
  [ "$status" -eq 0 ]
  no_branch app 12-trivial-fixes
  git -C "$ROOT/app" switch -q 12-trivial-fixes
  has_branch app 12-trivial-fixes
}

@test "deletes a Track 2 branch merged straight to main" {
  make_repo app
  feature app 7-prod-ci main
  merge_into app 7-prod-ci main
  git -C "$ROOT/app" switch -q dev
  run "$SCRIPT" --root "$ROOT"
  no_branch app 7-prod-ci
}

@test "deletes a merged branch whose remote is gone" {
  make_repo app
  feature app 5-thing
  merge_into app 5-thing dev
  git -C "$ROOT/app" push -q origin --delete 5-thing
  run "$SCRIPT" --root "$ROOT"
  [ "$status" -eq 0 ]
  no_branch app 5-thing
}

@test "single-track repo (no dev) judges against main" {
  make_repo org 0
  feature org 9-doc main
  merge_into org 9-doc main
  run "$SCRIPT" --root "$ROOT"
  no_branch org 9-doc
}

# ---------------------------------------------------------------------------
# What it keeps
# ---------------------------------------------------------------------------

@test "keeps main and dev" {
  make_repo app
  git -C "$ROOT/app" switch -q main
  feature app 5-thing
  run "$SCRIPT" --root "$ROOT"
  has_branch app main
  has_branch app dev
}

@test "keeps a branch with unmerged commits" {
  make_repo app
  feature app 5-thing
  git -C "$ROOT/app" switch -q dev
  run "$SCRIPT" --root "$ROOT"
  [ "$status" -eq 0 ]
  has_branch app 5-thing
  [[ "$output" == *"kept    5-thing (not pushed, or not yet"* ]]
}

@test "keeps a fresh, never-pushed branch with no commits" {
  make_repo app
  git -C "$ROOT/app" switch -q -c 6-new dev
  git -C "$ROOT/app" switch -q dev
  run "$SCRIPT" --root "$ROOT"
  has_branch app 6-new
}

@test "keeps a fresh branch whose upstream is origin/dev, not its own name" {
  make_repo app
  git -C "$ROOT/app" switch -q -c 6-new --track origin/dev
  git -C "$ROOT/app" switch -q dev
  run "$SCRIPT" --root "$ROOT"
  has_branch app 6-new
}

@test "keeps the current branch without --include-current" {
  make_repo app
  feature app 5-thing
  merge_into app 5-thing dev
  git -C "$ROOT/app" switch -q 5-thing
  run "$SCRIPT" --root "$ROOT"
  has_branch app 5-thing
  [[ "$output" == *"kept    5-thing (checked out)"* ]]
}

@test "keeps a merged branch checked out in another worktree" {
  make_repo app
  feature app 5-thing
  merge_into app 5-thing dev
  git -C "$ROOT/app" worktree add -q "$TMP/wt" 5-thing
  run "$SCRIPT" --root "$ROOT"
  has_branch app 5-thing
}

@test "does not delete a branch whose tip changes after the ancestry check" {
  make_repo app
  feature app 5-thing
  merge_into app 5-thing dev
  checked_tip="$(git -C "$ROOT/app" rev-parse 5-thing)"
  race_tip="$(git -C "$ROOT/app" commit-tree "$(git -C "$ROOT/app" rev-parse 'origin/main^{tree}')" -p "$(git -C "$ROOT/app" rev-parse origin/main)" -m 'unmerged race tip')"
  mkdir "$TMP/bin"
  real_git="$(command -v git)"
  cat > "$TMP/bin/git" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == -C && "${3:-}" == merge-base && "${4:-}" == --is-ancestor && "${5:-}" == "$RACE_CHECKED_TIP" ]]; then
  "$REAL_GIT" "$@"
  status=$?
  if [[ $status -eq 0 ]]; then
    "$REAL_GIT" -C "$RACE_REPO" update-ref "refs/heads/$RACE_BRANCH" "$RACE_TIP"
  fi
  exit "$status"
fi
exec "$REAL_GIT" "$@"
EOF
  chmod +x "$TMP/bin/git"

  run env PATH="$TMP/bin:$PATH" REAL_GIT="$real_git" RACE_REPO="$ROOT/app" \
    RACE_BRANCH=5-thing RACE_CHECKED_TIP="$checked_tip" RACE_TIP="$race_tip" \
    "$SCRIPT" --root "$ROOT"

  [ "$status" -ne 0 ]
  [ "$(git -C "$ROOT/app" rev-parse 5-thing)" = "$race_tip" ]
}

@test "--dry-run deletes nothing" {
  make_repo app
  feature app 5-thing
  merge_into app 5-thing dev
  run "$SCRIPT" --root "$ROOT" --dry-run
  [ "$status" -eq 0 ]
  has_branch app 5-thing
  [[ "$output" == *"would delete 5-thing"* ]]
}

# ---------------------------------------------------------------------------
# --include-current
# ---------------------------------------------------------------------------

@test "--include-current switches to dev, fast-forwards it, deletes the branch" {
  make_repo app
  feature app 5-thing
  merge_into app 5-thing dev
  git -C "$ROOT/app" switch -q 5-thing
  git -C "$ROOT/app" branch -q -f dev origin/dev~1   # local dev behind origin
  run "$SCRIPT" --root "$ROOT" --include-current
  [ "$status" -eq 0 ]
  no_branch app 5-thing
  [ "$(git -C "$ROOT/app" branch --show-current)" = dev ]
  [ "$(git -C "$ROOT/app" rev-parse dev)" = "$(git -C "$ROOT/app" rev-parse origin/dev)" ]
}

@test "--include-current leaves a dirty worktree alone" {
  make_repo app
  feature app 5-thing
  merge_into app 5-thing dev
  git -C "$ROOT/app" switch -q 5-thing
  touch "$ROOT/app/scratch"
  run "$SCRIPT" --root "$ROOT" --include-current
  has_branch app 5-thing
  [ "$(git -C "$ROOT/app" branch --show-current)" = 5-thing ]
}

@test "--include-current with a diverged local dev stays put and deletes nothing" {
  make_repo app
  feature app 5-thing
  merge_into app 5-thing dev
  git -C "$ROOT/app" reset -q --hard origin/dev~1
  git -C "$ROOT/app" commit -q --allow-empty -m "local-only dev commit"
  git -C "$ROOT/app" switch -q 5-thing
  run "$SCRIPT" --root "$ROOT" --include-current
  [ "$status" -eq 1 ]
  has_branch app 5-thing
  [ "$(git -C "$ROOT/app" branch --show-current)" = 5-thing ]
  [[ "$output" == *"stayed on 5-thing"* ]]
}

@test "deleting a branch also removes its tracking config" {
  make_repo app
  feature app 5-thing
  merge_into app 5-thing dev
  run "$SCRIPT" --root "$ROOT"
  no_branch app 5-thing
  run git -C "$ROOT/app" config --get branch.5-thing.merge
  [ "$status" -ne 0 ]
}

@test "--include-current --dry-run reports the switch but changes nothing" {
  make_repo app
  feature app 5-thing
  merge_into app 5-thing dev
  git -C "$ROOT/app" switch -q 5-thing
  run "$SCRIPT" --root "$ROOT" --include-current --dry-run
  has_branch app 5-thing
  [ "$(git -C "$ROOT/app" branch --show-current)" = 5-thing ]
  [[ "$output" == *"would switch to dev"* ]]
  [[ "$output" == *"would delete 5-thing"* ]]
}

# ---------------------------------------------------------------------------
# Discovery
# ---------------------------------------------------------------------------

@test "skips hidden clones under --root (e.g. .xpq-org-main)" {
  make_repo app
  git clone -q "$TMP/app.git" "$ROOT/.hidden" 2>/dev/null
  run "$SCRIPT" --root "$ROOT"
  [[ "$output" != *".hidden"* ]]
}
