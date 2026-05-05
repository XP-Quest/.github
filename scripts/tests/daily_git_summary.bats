#!/usr/bin/env bats
# Tests for scripts/daily_git_summary.sh
#
# Validates the three-layer commit-tracking scheme described in
# SR_ED_CONVENTIONS.md "How the parser stays accurate":
#
#   Layer 1 — commits whose subjects carry a '#NN: ' prefix are directly
#              attributed to the matching issue.
#   Layer 2 — commits without a prefix are attributed via the branch name
#              (<issue>-<slug>) that contains them.
#   Layer 3 — commits that survive both layers land in an (untracked) section
#              for human review.
#
# Reconciled commits (listed in journal/.reconciled) are suppressed from
# all sections.
#
# Environment variables used by the script and set here for isolation:
#   SEARCH_ROOT      — directory tree searched for git repos
#   OUTPUT_DIR       — where the markdown summary file is written
#   RECONCILED_FILE  — path to the Layer 3 skip list

SCRIPT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/daily_git_summary.sh"
HELPERS_DIR="$(dirname "$BATS_TEST_FILENAME")/helpers"

# Fixed test date so commits don't have to land "today".
TEST_DATE="2026-01-15"
GIT_DATE="${TEST_DATE}T12:00:00"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

setup() {
  TEST_DIR="$(mktemp -d)"

  # Prepend the mock gh binary so the script never contacts GitHub.
  export PATH="$HELPERS_DIR:$PATH"

  # Isolate script outputs.
  export SEARCH_ROOT="$TEST_DIR/repos"
  export OUTPUT_DIR="$TEST_DIR/output"
  export RECONCILED_FILE="$TEST_DIR/.reconciled"

  mkdir -p "$SEARCH_ROOT" "$OUTPUT_DIR"
  touch "$RECONCILED_FILE"
}

teardown() {
  rm -rf "$TEST_DIR"
}

# Create a minimal git repo in SEARCH_ROOT, return its path in $REPO_DIR.
make_repo() {
  local name="${1:-repo}"
  REPO_DIR="$SEARCH_ROOT/$name"
  mkdir -p "$REPO_DIR"
  git init -q "$REPO_DIR"
  git -C "$REPO_DIR" config user.email "test@example.com"
  git -C "$REPO_DIR" config user.name "Test User"
  # Add a fake origin so repo_identifier() can derive an org/repo string.
  git -C "$REPO_DIR" remote add origin "https://github.com/XP-Quest/$name"
}

# Make an empty commit in REPO_DIR with a controlled author/committer date.
make_commit() {
  local msg="$1"
  GIT_AUTHOR_DATE="$GIT_DATE" \
  GIT_COMMITTER_DATE="$GIT_DATE" \
    git -C "$REPO_DIR" commit --allow-empty -q -m "$msg"
}

# Return the short SHA of the most recent commit in REPO_DIR.
last_sha() {
  git -C "$REPO_DIR" log -1 --format='%h'
}

# ---------------------------------------------------------------------------
# Basic behaviour
# ---------------------------------------------------------------------------

@test "no git repos under SEARCH_ROOT: exits 0 without creating output file" {
  run bash "$SCRIPT" "$TEST_DATE"

  [ "$status" -eq 0 ]
  [ -z "$(ls -A "$OUTPUT_DIR")" ]
}

@test "repo exists but has no commits on TARGET_DATE: exits 0 without file" {
  make_repo "empty-repo"
  # Make a commit on a different date so the repo is not empty.
  GIT_AUTHOR_DATE="2025-06-01T10:00:00" \
  GIT_COMMITTER_DATE="2025-06-01T10:00:00" \
    git -C "$REPO_DIR" commit --allow-empty -q -m "#1: old commit"

  run bash "$SCRIPT" "$TEST_DATE"

  [ "$status" -eq 0 ]
  [ -z "$(ls -A "$OUTPUT_DIR")" ]
}

@test "output file is named github_summary-YYYY-MM-DD.md" {
  make_repo "testrepo"
  make_commit "#1: initial commit"

  run bash "$SCRIPT" "$TEST_DATE"

  [ "$status" -eq 0 ]
  [ -f "$OUTPUT_DIR/github_summary-${TEST_DATE}.md" ]
}

@test "output file header contains the target date" {
  make_repo "testrepo"
  make_commit "#1: initial commit"

  bash "$SCRIPT" "$TEST_DATE"

  grep -q "$TEST_DATE" "$OUTPUT_DIR/github_summary-${TEST_DATE}.md"
}

# ---------------------------------------------------------------------------
# Layer 1: direct '#NN: ' subject attribution
# ---------------------------------------------------------------------------

@test "Layer 1: commit with '#42: ...' subject is attributed to issue 42" {
  make_repo "testrepo"
  make_commit "#42: add FixedSizeChunker baseline at 512/64"

  bash "$SCRIPT" "$TEST_DATE"

  grep -q "#42" "$OUTPUT_DIR/github_summary-${TEST_DATE}.md"
}

@test "Layer 1: rendered subject strips the '#NN: ' prefix from the commit SHA line" {
  make_repo "testrepo"
  make_commit "#42: add FixedSizeChunker baseline at 512/64"

  bash "$SCRIPT" "$TEST_DATE"

  grep -q "add FixedSizeChunker baseline at 512/64" \
    "$OUTPUT_DIR/github_summary-${TEST_DATE}.md"
}

@test "Layer 1: two commits on the same issue both appear in the output" {
  make_repo "testrepo"
  make_commit "#42: add FixedSizeChunker baseline at 512/64"
  make_commit "#42: add token-count metrics to chunker output"

  bash "$SCRIPT" "$TEST_DATE"

  local out="$OUTPUT_DIR/github_summary-${TEST_DATE}.md"
  grep -c "#42" "$out" | grep -q "2"
}

@test "Layer 1: commits for different issues both appear in their own sections" {
  make_repo "testrepo"
  make_commit "#42: add FixedSizeChunker"
  make_commit "#58: add OIDC ingress filter"

  bash "$SCRIPT" "$TEST_DATE"

  local out="$OUTPUT_DIR/github_summary-${TEST_DATE}.md"
  grep -q "#42" "$out"
  grep -q "#58" "$out"
}

@test "Layer 1: repo section header uses the repository directory name" {
  make_repo "xpq-api"
  make_commit "#42: some work"

  bash "$SCRIPT" "$TEST_DATE"

  grep -q "## xpq-api" "$OUTPUT_DIR/github_summary-${TEST_DATE}.md"
}

# ---------------------------------------------------------------------------
# Layer 2: branch-name fallback attribution
# ---------------------------------------------------------------------------

@test "Layer 2: commit without '#NN: ' prefix is attributed via '<N>-<slug>' branch" {
  make_repo "testrepo"
  # Create a branch named 99-relevance-gate and commit on it.
  git -C "$REPO_DIR" checkout -q -b 99-relevance-gate
  make_commit "tune relevance threshold"

  bash "$SCRIPT" "$TEST_DATE"

  grep -q "#99" "$OUTPUT_DIR/github_summary-${TEST_DATE}.md"
}

@test "Layer 2: branch-recovered commit does NOT appear in (untracked)" {
  make_repo "testrepo"
  git -C "$REPO_DIR" checkout -q -b 99-relevance-gate
  make_commit "tune relevance threshold"

  bash "$SCRIPT" "$TEST_DATE"

  ! grep -q "(untracked)" "$OUTPUT_DIR/github_summary-${TEST_DATE}.md"
}

@test "Layer 2: origin/<N>-<slug> remote branch is preferred over local when both present" {
  make_repo "testrepo"
  # Simulate origin/10-feature by creating a remote-tracking ref directly.
  git -C "$REPO_DIR" checkout -q -b 10-feature
  make_commit "work on feature"
  local sha
  sha=$(last_sha)
  # Also create a local branch with a higher issue number that should lose.
  git -C "$REPO_DIR" branch 20-other-feature
  # Manually create a remote-tracking ref for the lower-numbered branch.
  git -C "$REPO_DIR" update-ref refs/remotes/origin/10-feature "$sha"

  bash "$SCRIPT" "$TEST_DATE"

  # Issue 10 (origin branch) should win over issue 20 (local-only).
  grep -q "#10" "$OUTPUT_DIR/github_summary-${TEST_DATE}.md"
}

# ---------------------------------------------------------------------------
# Layer 3: (untracked) section
# ---------------------------------------------------------------------------

@test "Layer 3: commit with no '#NN: ' and no matching branch lands in (untracked)" {
  make_repo "testrepo"
  # Commit on 'main' (no issue number in branch name) without a '#NN: ' prefix.
  make_commit "orphaned work without an issue reference"

  bash "$SCRIPT" "$TEST_DATE"

  grep -q "(untracked)" "$OUTPUT_DIR/github_summary-${TEST_DATE}.md"
}

@test "Layer 3: (untracked) entry includes the repo name and short SHA" {
  make_repo "xpq-api"
  make_commit "orphaned commit"
  local sha
  sha=$(last_sha)

  bash "$SCRIPT" "$TEST_DATE"

  grep -q "xpq-api" "$OUTPUT_DIR/github_summary-${TEST_DATE}.md"
  grep -q "$sha"   "$OUTPUT_DIR/github_summary-${TEST_DATE}.md"
}

@test "Layer 3: (untracked) section includes reconcile instructions" {
  make_repo "testrepo"
  make_commit "no issue ref"

  bash "$SCRIPT" "$TEST_DATE"

  grep -q "reconcile_commit.sh" "$OUTPUT_DIR/github_summary-${TEST_DATE}.md"
}

# ---------------------------------------------------------------------------
# Reconciled commits (Layer 3 skip list)
# ---------------------------------------------------------------------------

@test "reconciled SHA is suppressed from (untracked) output" {
  make_repo "testrepo"
  make_commit "orphaned commit that was later reconciled"
  local sha
  sha=$(last_sha)

  # Register the commit in the reconciled skip list.
  echo "$sha  reconciled to XP-Quest/testrepo#7 on 2026-01-16" >> "$RECONCILED_FILE"

  bash "$SCRIPT" "$TEST_DATE"

  # Either no output file (if this was the only commit) or SHA not present.
  if [ -f "$OUTPUT_DIR/github_summary-${TEST_DATE}.md" ]; then
    ! grep -q "$sha" "$OUTPUT_DIR/github_summary-${TEST_DATE}.md"
  else
    true
  fi
}

@test "reconciled SHA does not suppress a different, unreconciled commit" {
  make_repo "testrepo"
  make_commit "commit A — will be reconciled"
  local sha_a
  sha_a=$(last_sha)
  make_commit "#55: commit B — tracked via prefix"

  echo "$sha_a  reconciled to XP-Quest/testrepo#7 on 2026-01-16" >> "$RECONCILED_FILE"

  bash "$SCRIPT" "$TEST_DATE"

  grep -q "#55" "$OUTPUT_DIR/github_summary-${TEST_DATE}.md"
}

@test "reconciled file lines starting with '#' are treated as comments and ignored" {
  make_repo "testrepo"
  make_commit "orphaned commit"
  local sha
  sha=$(last_sha)

  # Write the SHA as a comment — should NOT suppress it.
  echo "# $sha  this line is a comment" >> "$RECONCILED_FILE"

  bash "$SCRIPT" "$TEST_DATE"

  grep -q "$sha" "$OUTPUT_DIR/github_summary-${TEST_DATE}.md"
}

# ---------------------------------------------------------------------------
# Argument validation
# ---------------------------------------------------------------------------

@test "invalid date argument exits with status 1" {
  run bash "$SCRIPT" "not-a-date"

  [ "$status" -eq 1 ]
  [[ "$output" == *"invalid date"* ]]
}

@test "invalid date error message echoes the bad input" {
  run bash "$SCRIPT" "not-a-date"

  [[ "$output" == *"not-a-date"* ]]
}

# ---------------------------------------------------------------------------
# Multiple repos
# ---------------------------------------------------------------------------

@test "commits from multiple repos each get their own section" {
  make_repo "xpq-api"
  make_commit "#42: api work"

  make_repo "xpq-web"
  make_commit "#58: web work"

  bash "$SCRIPT" "$TEST_DATE"

  local out="$OUTPUT_DIR/github_summary-${TEST_DATE}.md"
  grep -q "## xpq-api" "$out"
  grep -q "## xpq-web" "$out"
}
