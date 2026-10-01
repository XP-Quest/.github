#!/usr/bin/env bash
# branch-cleanup.sh: delete the head branches of work that has reached the
# default branch (main).
#
# Called by .github/workflows/branch-cleanup-reusable.yml for a PR merged into
# main. GitHub's own "Automatically delete head branches" cannot exempt the
# N-trivial-fixes catch-all branches or filter by base, so cleanup is done here
# instead. See SR_ED_CONVENTIONS.md "Branch hygiene".
#
# Candidates:
#   - the PR's own head branch (Track 2 / single-track PRs), and
#   - the head branch of every merged same-repo PR associated with the PR's
#     commits. A dev -> main promotion carries exactly the work merged to dev
#     since the last promotion, so this finds the feature branches that rode it.
#
# Never deleted:
#   - main, dev, the default branch, or an N-trivial-fixes branch
#   - a branch that is the head or the base of an open PR
#   - a branch whose tip is not the final head of a merged PR (new commits were
#     pushed after the merge, so deleting would lose unmerged work)
#   - heads from forks (not branches of this repo)
#
# Usage: branch-cleanup.sh --repo OWNER/REPO --pr N [--dry-run]
#
# Requires: gh (authenticated; contents:write to delete) and jq.
# Exit: 0 on success (skips are not errors), 1 if any delete failed, 2 on bad usage.

set -euo pipefail

usage() {
  sed -n '/^# Usage:/,/^# Exit:/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

repo=""
pr=""
dry_run=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)    repo="${2:-}"; shift 2 ;;
    --pr)      pr="${2:-}"; shift 2 ;;
    --dry-run) dry_run=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ ! "$repo" =~ ^[^/]+/[^/]+$ ]]; then
  echo "Error: --repo must be OWNER/REPO (got '${repo}')" >&2
  usage >&2
  exit 2
fi
if [[ ! "$pr" =~ ^[0-9]+$ ]]; then
  echo "Error: --pr must be a PR number (got '${pr}')" >&2
  usage >&2
  exit 2
fi

owner="${repo%%/*}"

pr_json=$(gh api "repos/$repo/pulls/$pr")
merged_at=$(jq -r '.merged_at // empty' <<< "$pr_json")
base_ref=$(jq -r '.base.ref' <<< "$pr_json")
default_branch=$(gh api "repos/$repo" | jq -r '.default_branch')

if [[ -z "$merged_at" ]]; then
  echo "PR #$pr is not merged; nothing to clean up."
  exit 0
fi
if [[ "$base_ref" != "$default_branch" ]]; then
  echo "PR #$pr merged into '$base_ref', not '$default_branch'; nothing to clean up."
  exit 0
fi

# Candidate lines are "<branch>\t<final head sha>\t<PR number>". A branch reused
# by several merged PRs (e.g. a trivial-fixes branch) appears more than once.
# API failures here abort the run (set -e) rather than yielding a partial list,
# since a branch missed now is never revisited by a later promotion.
candidates=$(jq -r --arg repo "$repo" \
  'select(.head.repo.full_name == $repo) | [.head.ref, .head.sha, .number] | @tsv' \
  <<< "$pr_json")

# --paginate emits one JSON array per page; jq streams over each of them.
shas=$(gh api --paginate "repos/$repo/pulls/$pr/commits" | jq -r '.[].sha')
while read -r sha; do
  [[ -z "$sha" ]] && continue
  found=$(gh api "repos/$repo/commits/$sha/pulls" \
    | jq -r --arg repo "$repo" \
        '.[] | select(.merged_at != null and .head.repo.full_name == $repo)
             | [.head.ref, .head.sha, .number] | @tsv')
  [[ -n "$found" ]] && candidates+=$'\n'"$found"
done <<< "$shas"

summary=()
failed=0

record() {  # record <outcome> <branch> <detail>
  printf '%-8s %s  (%s)\n' "$1" "$2" "$3"
  summary+=("| $1 | \`$2\` | $3 |")
}

open_prs() {  # open_prs <head|base> <branch> -> number of open PRs
  local key="$1" branch="$2" value="$2"
  [[ "$key" == "head" ]] && value="$owner:$branch"
  gh api -X GET "repos/$repo/pulls" -f state=open -f "$key=$value" | jq 'length'
}

while read -r branch; do
  [[ -z "$branch" ]] && continue

  if [[ "$branch" == "main" || "$branch" == "dev" || "$branch" == "$default_branch" ]]; then
    record skipped "$branch" "integration branch"
    continue
  fi
  if [[ "$branch" =~ ^[0-9]+-trivial-fixes$ ]]; then
    record skipped "$branch" "permanent trivial-fixes branch"
    continue
  fi

  if ! ref_json=$(gh api "repos/$repo/git/ref/heads/$branch" 2>&1); then
    if grep -q 'HTTP 404' <<< "$ref_json"; then
      record skipped "$branch" "already gone"
    else
      record FAILED "$branch" "ref lookup failed"
      failed=1
    fi
    continue
  fi
  tip=$(jq -r '.object.sha' <<< "$ref_json")

  # Every merged PR that used this branch; the tip must be the final head of one.
  prs=$(awk -F'\t' -v b="$branch" '$1 == b { print $3 }' <<< "$candidates" | sort -un | paste -sd, - | sed 's/,/, #/g')
  if ! awk -F'\t' -v b="$branch" -v t="$tip" '$1 == b && $2 == t { found = 1 } END { exit !found }' <<< "$candidates"; then
    record skipped "$branch" "tip ${tip:0:7} is past the merged head; unmerged commits (#$prs)"
    continue
  fi

  open_as_head=$(open_prs head "$branch")
  if [[ "$open_as_head" != "0" ]]; then
    record skipped "$branch" "head of an open PR"
    continue
  fi
  open_as_base=$(open_prs base "$branch")
  if [[ "$open_as_base" != "0" ]]; then
    record skipped "$branch" "base of an open PR"
    continue
  fi

  if [[ "$dry_run" -eq 1 ]]; then
    record would "$branch" "dry run; tip ${tip:0:7}, PR #$prs"
  elif gh api -X DELETE "repos/$repo/git/refs/heads/$branch" >/dev/null 2>&1; then
    record deleted "$branch" "tip ${tip:0:7}, PR #$prs"
  else
    record FAILED "$branch" "delete request failed"
    failed=1
  fi
done < <(cut -f1 <<< "$candidates" | sort -u)

if [[ ${#summary[@]} -eq 0 ]]; then
  echo "No candidate branches for PR #$pr."
fi

# Surface the outcome on the Actions run page when running in CI.
if [[ -n "${GITHUB_STEP_SUMMARY:-}" && ${#summary[@]} -gt 0 ]]; then
  {
    echo "### Branch cleanup after PR #$pr"
    echo
    echo "| Outcome | Branch | Detail |"
    echo "|---|---|---|"
    printf '%s\n' "${summary[@]}"
  } >> "$GITHUB_STEP_SUMMARY"
fi

exit "$failed"
