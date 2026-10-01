#!/usr/bin/env bats
# Tests for scripts/branch-cleanup.sh
#
# The script deletes remote branches, so these tests pin down what it must NOT
# delete as carefully as what it must: integration branches, N-trivial-fixes,
# branches with open PRs, branches that moved past their merged head, forks.
#
# `gh` is replaced by helpers/mock_gh_api, which serves canned `gh api`
# responses keyed on the exact argument string and records every DELETE.

SCRIPT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/branch-cleanup.sh"
MOCK="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)/helpers/mock_gh_api"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

setup() {
  MOCK_GH_DIR="$(mktemp -d)"
  export MOCK_GH_DIR
  mkdir "$MOCK_GH_DIR/bin"
  cp "$MOCK" "$MOCK_GH_DIR/bin/gh"
  chmod +x "$MOCK_GH_DIR/bin/gh"
  PATH="$MOCK_GH_DIR/bin:$PATH"
  REPO="org/app"
  stub "api repos/$REPO" '{"default_branch":"main"}'
}

teardown() {
  rm -rf "$MOCK_GH_DIR"
}

# stub <gh args> <stdout>: canned response for that exact call.
stub() {
  printf '%s' "$2" > "$MOCK_GH_DIR/$(printf '%s' "$1" | md5sum | cut -d' ' -f1)"
}

# stub_fail <gh args> <stderr>: make that exact call exit 1.
stub_fail() {
  printf '%s\n' "$2" > "$MOCK_GH_DIR/$(printf '%s' "$1" | md5sum | cut -d' ' -f1).fail"
}

# pr_json NUMBER HEAD_REF HEAD_SHA BASE MERGED(true|false) [HEAD_REPO]
pr_json() {
  local merged_at='"2026-09-30T00:00:00Z"'
  [[ "$5" == "true" ]] || merged_at=null
  printf '{"number":%s,"merged_at":%s,"base":{"ref":"%s"},"head":{"ref":"%s","sha":"%s","repo":{"full_name":"%s"}}}' \
    "$1" "$merged_at" "$4" "$2" "$3" "${6:-$REPO}"
}

# stub_pr <pr_json args>: GET repos/<r>/pulls/N
stub_pr() { stub "api repos/$REPO/pulls/$1" "$(pr_json "$@")"; }

# stub_pr_commits N SHA...: the commits of PR N
stub_pr_commits() {
  local n="$1"; shift
  stub "api --paginate repos/$REPO/pulls/$n/commits" \
    "[$(printf '{"sha":"%s"},' "$@" | sed 's/,$//')]"
}

# stub_commit_prs SHA PR_JSON...: the PRs a commit belongs to
stub_commit_prs() {
  local sha="$1"; shift
  stub "api repos/$REPO/commits/$sha/pulls" "[$(IFS=,; echo "$*")]"
}

# stub_ref BRANCH SHA: current tip of a remote branch
stub_ref() { stub "api repos/$REPO/git/ref/heads/$1" "{\"object\":{\"sha\":\"$2\"}}"; }

# stub_open head|base BRANCH: one open PR with that head / base
stub_open() {
  local value="$2"
  [[ "$1" == "head" ]] && value="org:$2"
  stub "api -X GET repos/$REPO/pulls -f state=open -f $1=$value" '[{"number":99}]'
}

# A merged feature -> main PR (Track 2 / single-track) from branch $1 at sha $2.
track2_pr() {
  stub_pr 5 "$1" "$2" main true
  stub_pr_commits 5 c1
  stub_commit_prs c1 "$(pr_json 5 "$1" "$2" main true)"
}

deletes() { cat "$MOCK_GH_DIR/deletes" 2>/dev/null || true; }

# ---------------------------------------------------------------------------
# Usage / argument validation
# ---------------------------------------------------------------------------

@test "usage: --help exits 0 and shows usage" {
  run "$SCRIPT" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage: branch-cleanup.sh"* ]]
}

@test "usage: missing --repo exits 2" {
  run "$SCRIPT" --pr 5
  [ "$status" -eq 2 ]
  [[ "$output" == *"--repo must be OWNER/REPO"* ]]
}

@test "usage: non-numeric --pr exits 2" {
  run "$SCRIPT" --repo "$REPO" --pr abc
  [ "$status" -eq 2 ]
  [[ "$output" == *"--pr must be a PR number"* ]]
}

@test "usage: unknown argument exits 2" {
  run "$SCRIPT" --repo "$REPO" --pr 5 --force
  [ "$status" -eq 2 ]
  [[ "$output" == *"Unknown argument: --force"* ]]
}

# ---------------------------------------------------------------------------
# Which PRs trigger cleanup
# ---------------------------------------------------------------------------

@test "skips a PR that was closed without merging" {
  stub_pr 5 7-feature f1f1f1f1 main false
  run "$SCRIPT" --repo "$REPO" --pr 5
  [ "$status" -eq 0 ]
  [[ "$output" == *"not merged"* ]]
  [ -z "$(deletes)" ]
}

@test "skips a PR merged into dev rather than main" {
  stub_pr 5 7-feature f1f1f1f1 dev true
  run "$SCRIPT" --repo "$REPO" --pr 5
  [ "$status" -eq 0 ]
  [[ "$output" == *"merged into 'dev', not 'main'"* ]]
  [ -z "$(deletes)" ]
}

# ---------------------------------------------------------------------------
# Track 2 / single-track: the PR's own head
# ---------------------------------------------------------------------------

@test "deletes the head of a merged feature -> main PR" {
  track2_pr 7-feature f1f1f1f1
  stub_ref 7-feature f1f1f1f1
  run "$SCRIPT" --repo "$REPO" --pr 5
  [ "$status" -eq 0 ]
  [[ "$output" == *"deleted  7-feature"* ]]
  [ "$(deletes)" = "7-feature" ]
}

@test "dry run reports what it would delete but deletes nothing" {
  track2_pr 7-feature f1f1f1f1
  stub_ref 7-feature f1f1f1f1
  run "$SCRIPT" --repo "$REPO" --pr 5 --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"would    7-feature"* ]]
  [ -z "$(deletes)" ]
}

@test "ignores a head branch from a fork" {
  stub_pr 5 7-feature f1f1f1f1 main true someone/app
  stub_pr_commits 5 c1
  stub_commit_prs c1 "$(pr_json 5 7-feature f1f1f1f1 main true someone/app)"
  run "$SCRIPT" --repo "$REPO" --pr 5
  [ "$status" -eq 0 ]
  [[ "$output" == *"No candidate branches"* ]]
  [ -z "$(deletes)" ]
}

# ---------------------------------------------------------------------------
# dev -> main promotion: the feature branches that rode it
# ---------------------------------------------------------------------------

@test "promotion deletes every feature branch it carried, but never dev" {
  stub_pr 10 dev d1d1d1d1 main true
  stub_pr_commits 10 c1 c2
  stub_commit_prs c1 "$(pr_json 8 7-alpha a8a8a8a8 dev true)"
  stub_commit_prs c2 "$(pr_json 9 8-beta b9b9b9b9 dev true)"
  stub_ref 7-alpha a8a8a8a8
  stub_ref 8-beta b9b9b9b9
  run "$SCRIPT" --repo "$REPO" --pr 10
  [ "$status" -eq 0 ]
  [[ "$output" == *"skipped  dev  (integration branch)"* ]]
  [ "$(deletes | sort)" = "$(printf '7-alpha\n8-beta')" ]
}

@test "promotion ignores associated PRs that are not merged" {
  stub_pr 10 dev d1d1d1d1 main true
  stub_pr_commits 10 c1
  stub_commit_prs c1 "$(pr_json 8 7-alpha a8a8a8a8 dev false)"
  stub_ref 7-alpha a8a8a8a8
  run "$SCRIPT" --repo "$REPO" --pr 10
  [ "$status" -eq 0 ]
  [ -z "$(deletes)" ]
}

@test "a branch used by several merged PRs is deleted once, when the tip matches the latest" {
  stub_pr 10 dev d1d1d1d1 main true
  stub_pr_commits 10 c1 c2
  stub_commit_prs c1 "$(pr_json 14 5-reused 0101010101 dev true)"
  stub_commit_prs c2 "$(pr_json 16 5-reused 0202020202 dev true)"
  stub_ref 5-reused 0202020202
  run "$SCRIPT" --repo "$REPO" --pr 10
  [ "$status" -eq 0 ]
  [ "$(deletes)" = "5-reused" ]
}

# ---------------------------------------------------------------------------
# What must never be deleted
# ---------------------------------------------------------------------------

@test "never deletes an N-trivial-fixes branch" {
  track2_pr 12-trivial-fixes f1f1f1f1
  stub_ref 12-trivial-fixes f1f1f1f1
  run "$SCRIPT" --repo "$REPO" --pr 5
  [ "$status" -eq 0 ]
  [[ "$output" == *"skipped  12-trivial-fixes  (permanent trivial-fixes branch)"* ]]
  [ -z "$(deletes)" ]
}

@test "a branch merely named like trivial-fixes is not exempt" {
  track2_pr 12-trivial-fixes-extra f1f1f1f1
  stub_ref 12-trivial-fixes-extra f1f1f1f1
  run "$SCRIPT" --repo "$REPO" --pr 5
  [ "$status" -eq 0 ]
  [ "$(deletes)" = "12-trivial-fixes-extra" ]
}

@test "never deletes a branch whose tip moved past the merged head" {
  track2_pr 7-feature f1f1f1f1
  stub_ref 7-feature e2e2e2e2
  run "$SCRIPT" --repo "$REPO" --pr 5
  [ "$status" -eq 0 ]
  [[ "$output" == *"skipped  7-feature"* ]]
  [[ "$output" == *"unmerged commits (#5)"* ]]
  [ -z "$(deletes)" ]
}

@test "never deletes the head of an open PR" {
  track2_pr 7-feature f1f1f1f1
  stub_ref 7-feature f1f1f1f1
  stub_open head 7-feature
  run "$SCRIPT" --repo "$REPO" --pr 5
  [ "$status" -eq 0 ]
  [[ "$output" == *"head of an open PR"* ]]
  [ -z "$(deletes)" ]
}

@test "never deletes the base of an open PR (epic branch with live sub-PRs)" {
  track2_pr 7-epic f1f1f1f1
  stub_ref 7-epic f1f1f1f1
  stub_open base 7-epic
  run "$SCRIPT" --repo "$REPO" --pr 5
  [ "$status" -eq 0 ]
  [[ "$output" == *"base of an open PR"* ]]
  [ -z "$(deletes)" ]
}

@test "an already-deleted branch is a skip, not an error" {
  track2_pr 7-feature f1f1f1f1
  run "$SCRIPT" --repo "$REPO" --pr 5
  [ "$status" -eq 0 ]
  [[ "$output" == *"skipped  7-feature  (already gone)"* ]]
  [ -z "$(deletes)" ]
}

# ---------------------------------------------------------------------------
# Failures are loud
# ---------------------------------------------------------------------------

@test "a failed delete exits 1" {
  track2_pr 7-feature f1f1f1f1
  stub_ref 7-feature f1f1f1f1
  stub_fail "api -X DELETE repos/$REPO/git/refs/heads/7-feature" "gh: Forbidden (HTTP 403)"
  run "$SCRIPT" --repo "$REPO" --pr 5
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAILED   7-feature"* ]]
}

@test "a non-404 ref lookup failure exits 1 rather than reading as already gone" {
  track2_pr 7-feature f1f1f1f1
  stub_fail "api repos/$REPO/git/ref/heads/7-feature" "gh: Server Error (HTTP 502)"
  run "$SCRIPT" --repo "$REPO" --pr 5
  [ "$status" -eq 1 ]
  [[ "$output" == *"ref lookup failed"* ]]
  [ -z "$(deletes)" ]
}

@test "a failure listing the PR's commits aborts before deleting anything" {
  stub_pr 5 7-feature f1f1f1f1 main true
  stub_fail "api --paginate repos/$REPO/pulls/5/commits" "gh: Server Error (HTTP 502)"
  stub_ref 7-feature f1f1f1f1
  run "$SCRIPT" --repo "$REPO" --pr 5
  [ "$status" -ne 0 ]
  [ -z "$(deletes)" ]
}

# ---------------------------------------------------------------------------
# CI summary
# ---------------------------------------------------------------------------

@test "writes a table to GITHUB_STEP_SUMMARY when set" {
  track2_pr 7-feature f1f1f1f1
  stub_ref 7-feature f1f1f1f1
  export GITHUB_STEP_SUMMARY="$MOCK_GH_DIR/summary.md"
  run "$SCRIPT" --repo "$REPO" --pr 5
  [ "$status" -eq 0 ]
  grep -qF '### Branch cleanup after PR #5' "$GITHUB_STEP_SUMMARY"
  grep -qF '| deleted | `7-feature` | tip f1f1f1f, PR #5 |' "$GITHUB_STEP_SUMMARY"
}
