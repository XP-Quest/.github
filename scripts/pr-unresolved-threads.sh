#!/usr/bin/env bash
# pr-unresolved-threads.sh: list the unresolved review threads on a PR; exit 1 if any.
#
# The final gate of the xpq-pr-review-cycle skill: "no unresolved threads" is an exit code,
# not a claim. Reads only; it never replies to or resolves a thread.
#
# Usage: pr-unresolved-threads.sh <repo> <pr-number>
#   <repo> is owner/name, or a bare name in the XP-Quest org (the org repo is ".github").
#
# Output: one tab-separated line per unresolved thread on stdout:
#   <thread node id>  <first commenter>  <path>:<line>  <first line of the comment>
# Exit:   0 none unresolved, 1 some unresolved, 2 usage or API error.

set -euo pipefail

if [[ $# -ne 2 || ! "$2" =~ ^[0-9]+$ ]]; then
  echo "Usage: $(basename "$0") <repo> <pr-number>" >&2
  exit 2
fi

repo=$1
pr=$2
[[ "$repo" == */* ]] || repo="XP-Quest/$repo"
owner=${repo%%/*}
name=${repo#*/}

query='
query($owner:String!,$repo:String!,$pr:Int!,$endCursor:String){
  repository(owner:$owner,name:$repo){ pullRequest(number:$pr){
    reviewThreads(first:50, after:$endCursor){
      pageInfo{ hasNextPage endCursor }
      nodes{ id isResolved path line originalLine
        comments(first:1){ nodes{ author{login} body } } } } } } }'

filter='.data.repository.pullRequest.reviewThreads.nodes[]
  | select(.isResolved | not)
  | [ .id,
      (.comments.nodes[0].author.login // "unknown"),
      "\(.path):\(.line // .originalLine // 0)",
      ((.comments.nodes[0].body // "") | split("\n")[0] | .[0:80]) ]
  | @tsv'

if ! unresolved=$(gh api graphql --paginate \
    -f owner="$owner" -f repo="$name" -F pr="$pr" -f query="$query" --jq "$filter"); then
  echo "Error: could not read review threads for $repo#$pr" >&2
  exit 2
fi

if [[ -z "$unresolved" ]]; then
  echo "0 unresolved threads on $repo#$pr" >&2
  exit 0
fi

printf '%s\n' "$unresolved"
echo "$(printf '%s\n' "$unresolved" | wc -l | tr -d ' ') unresolved thread(s) on $repo#$pr" >&2
exit 1
