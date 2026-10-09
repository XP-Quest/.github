#!/usr/bin/env bats
# Tests for scripts/xpq-pr-merge-guard.sh
#
# The guard is a PreToolUse hook: it reads the hook JSON on stdin and prints a deny
# decision (exit 0) to block, or prints nothing to allow. It blocks PR merges by any
# gh/API route and pushes to main, master or dev. It is a backstop against accidents and
# injected text, not a security boundary, so these tests cover the realistic spellings
# and not every possible obfuscation.

GUARD="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/xpq-pr-merge-guard.sh"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

setup() {
  REPO="$BATS_TEST_TMPDIR/repo"
  git init -q -b 67-feature "$REPO"
  git -C "$REPO" config user.email "test@example.com"
  git -C "$REPO" config user.name "Test User"
  git -C "$REPO" commit -q --allow-empty -m "#67: init"
}

# on_branch <name>: put the test repo on the given branch.
on_branch() {
  git -C "$REPO" switch -q -C "$1"
}

# guard <command>: feed the hook the JSON a Bash tool call would send.
guard() {
  python3 -c '
import json, sys
print(json.dumps({"tool_input": {"command": sys.argv[1]}, "cwd": sys.argv[2]}))
' "$1" "$REPO" | bash "$GUARD"
}

assert_denied() {
  run guard "$1"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"permissionDecision": "deny"'* ]]
}

assert_allowed() {
  run guard "$1"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# gh pr merge
# ---------------------------------------------------------------------------

@test "denies gh pr merge" {
  assert_denied 'gh pr merge 5'
}

@test "denies gh pr merge with flags" {
  assert_denied 'gh pr merge 5 --squash --delete-branch'
  assert_denied 'gh pr merge --auto 5'
}

@test "denies gh pr merge wrapped in bash -c" {
  assert_denied 'bash -c "gh pr merge 5"'
}

@test "denies gh pr merge with extra whitespace" {
  assert_denied 'gh pr   merge 5'
}

@test "denies gh pr merge with a repo flag before or after pr" {
  assert_denied 'gh -R XP-Quest/xpq-api pr merge 5'
  assert_denied 'gh --repo=XP-Quest/xpq-api pr merge 5'
  assert_denied 'gh pr -R XP-Quest/xpq-api merge 5'
}

@test "denial output names the blocked command" {
  run guard 'gh pr merge 5'
  [[ "$output" == *"Blocked command: gh pr merge 5"* ]]
}

# ---------------------------------------------------------------------------
# Merge through the API
# ---------------------------------------------------------------------------

@test "denies the REST merge endpoint" {
  assert_denied 'gh api -X PUT repos/XP-Quest/xpq-api/pulls/5/merge'
  assert_denied 'gh api repos/XP-Quest/xpq-api/pulls/$N/merge -X PUT -f merge_method=squash'
  assert_denied 'curl -X PUT https://api.github.com/repos/XP-Quest/xpq-api/pulls/5/merge'
}

@test "denies the REST branch-merge endpoint" {
  assert_denied 'gh api -X POST repos/XP-Quest/xpq-api/merges -f base=dev -f head=x'
}

@test "denies the GraphQL merge mutations" {
  assert_denied 'gh api graphql -f query="mutation{mergePullRequest(input:{pullRequestId:\"X\"}){clientMutationId}}"'
  assert_denied 'gh api graphql -f query="mutation{enablePullRequestAutoMerge(input:{pullRequestId:\"X\"}){clientMutationId}}"'
  assert_denied 'gh api graphql -f query="mutation{mergeBranch(input:{repositoryId:\"X\"}){clientMutationId}}"'
}

@test "allows the API calls the review-cycle skill uses" {
  assert_allowed 'gh api -X PATCH repos/XP-Quest/xpq-api/pulls/5 -f title=x'
  assert_allowed 'gh api -X POST repos/XP-Quest/xpq-api/pulls/5/comments/1/replies -F body=@/tmp/r.md'
  assert_allowed 'gh api graphql -f query="mutation{resolveReviewThread(input:{threadId:\"X\"}){thread{isResolved}}}"'
  assert_allowed 'gh api graphql --paginate -f query="query{repository{pullRequest{reviewThreads{nodes{id}}}}}"'
}

@test "allows read-only gh pr subcommands" {
  assert_allowed 'gh pr view 5 --json mergeable,mergeStateStatus'
  assert_allowed 'gh pr list --state open'
  assert_allowed 'gh pr checks 5'
  assert_allowed 'gh pr comment 5 --body-file /tmp/c.md'
}

@test "allows searching the repo for a merge mutation name" {
  assert_allowed 'grep -rn mergePullRequest scripts/'
}

# ---------------------------------------------------------------------------
# git push to the integration branches
# ---------------------------------------------------------------------------

@test "denies pushing a refspec to main, master or dev" {
  assert_denied 'git push origin main'
  assert_denied 'git push origin master'
  assert_denied 'git push origin dev'
  assert_denied 'git push origin HEAD:dev'
  assert_denied 'git push origin HEAD:refs/heads/main'
}

@test "denies forced, deleting and plus-prefixed pushes to dev" {
  assert_denied 'git push --force-with-lease origin dev'
  assert_denied 'git push origin +dev'
  assert_denied 'git push --delete origin dev'
  assert_denied 'git push origin :dev'
}

@test "denies push --all and --mirror" {
  assert_denied 'git push --all origin'
  assert_denied 'git push --mirror origin'
}

@test "denies a push to main behind cd, -C or bash -c" {
  assert_denied 'cd /somewhere && git push origin main'
  assert_denied "git -C $BATS_TEST_TMPDIR push origin main"
  assert_denied 'bash -c "git push origin main"'
}

@test "denies a bare push while on dev or main" {
  on_branch dev
  assert_denied 'git push'
  on_branch main
  assert_denied 'git push'
  assert_denied 'git push origin'
}

@test "denies pushing HEAD while on dev or main" {
  on_branch dev
  assert_denied 'git push origin HEAD'
  assert_denied 'git push -u origin HEAD'
}

@test "allows pushing an issue branch" {
  assert_allowed 'git push -u origin 67-feature'
  assert_allowed 'git push origin HEAD:67-feature'
  assert_allowed 'git push --force-with-lease origin 67-feature'
}

@test "allows a bare push and a HEAD push while on an issue branch" {
  assert_allowed 'git push'
  assert_allowed 'git push origin'
  assert_allowed 'git push -u origin HEAD'
}

@test "allows a branch whose name merely contains dev or main" {
  assert_allowed 'git push origin 67-dev-tooling'
  assert_allowed 'git push origin 12-main-menu'
}

@test "allows pushing a release tag" {
  assert_allowed 'git push origin v1.2.3'
}

@test "allows commit text that mentions pushing to main" {
  assert_allowed 'git commit -m "#67: never git push origin main from Claude"'
}

# ---------------------------------------------------------------------------
# Robustness
# ---------------------------------------------------------------------------

@test "allows an ordinary command" {
  assert_allowed 'ls -la'
}

@test "exits quietly on empty or malformed input" {
  run bash -c "printf '' | bash '$GUARD'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  run bash -c "printf 'not json' | bash '$GUARD'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  run bash -c "printf '{}' | bash '$GUARD'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
