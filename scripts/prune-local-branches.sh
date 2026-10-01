#!/usr/bin/env bash
# prune-local-branches.sh: delete local branches whose work is already on the
# integration branch, in every clone under ~/xpquest.
#
# branch-cleanup.sh prunes the *remote* branches once work reaches main; local
# clones keep every branch until deleted by hand, so `git branch` stops saying
# what is outstanding. This keeps only branches with work not yet integrated.
# See SR_ED_CONVENTIONS.md "Branch hygiene".
#
# A local branch is pruned when its tip is reachable from origin/dev (deployable
# repos) or origin/main (all repos; xpq-org has no dev, and Track 2 branches go
# straight to main). Reachable means every commit is already integrated, so no
# work can be lost. N-trivial-fixes branches are pruned like any other; their
# remote branch is permanent, so they come back with `git switch N-trivial-fixes`.
# Any pruned branch whose remote still exists comes back the same way.
#
# Never deleted:
#   - main or dev
#   - a branch checked out in any worktree (clones are shared by concurrent
#     sessions), except the current branch with --include-current
#   - a branch with commits not on origin/dev or origin/main
#   - a branch never pushed under its own name (e.g. new, no commits yet)
#
# Usage: prune-local-branches.sh [--dry-run] [--include-current] [--root DIR] [REPO ...]
#
#   REPO               clone(s) to prune; default every git clone directly under --root
#   --root DIR         where to look for clones (default ~/xpquest)
#   --dry-run          report what would be deleted; change nothing
#   --include-current  also prune the checked-out branch of a clean worktree: switch
#                      to the integration branch, fast-forward it, then delete
#
# Exit: 0 on success (kept branches are not errors), 1 if any delete or switch
# failed, 2 on bad usage.

set -euo pipefail

usage() {
  sed -n '/^# Usage:/,/^# Exit:/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

root="${HOME}/xpquest"
dry_run=0
include_current=0
repos=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --root)            root="${2:-}"; shift 2 ;;
    --dry-run)         dry_run=1; shift ;;
    --include-current) include_current=1; shift ;;
    -h|--help)         usage; exit 0 ;;
    -*) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
    *)  repos+=("$1"); shift ;;
  esac
done

if [[ ${#repos[@]} -eq 0 ]]; then
  if [[ ! -d "$root" ]]; then
    echo "Error: --root '${root}' is not a directory" >&2
    exit 2
  fi
  for d in "$root"/*/; do
    d="${d%/}"
    # A clone's top level only — not a subdirectory that happens to sit in one.
    [[ -e "$d/.git" ]] && repos+=("$d")
  done
fi

failed=0
pruned_total=0

# merged <repo> <branch>: was the branch pushed under its own name, and is its
# tip on origin/dev or origin/main? The push check keeps a fresh branch with no
# commits yet (tip == origin/dev) from looking "merged". Every branch that went
# through a PR was pushed with -u, so its upstream is origin/<branch>, even after
# branch-cleanup deletes the remote side ("gone").
merged() {
  local ref
  [[ "$(git -C "$1" config --get "branch.$2.remote" || true)" == "origin" \
     && "$(git -C "$1" config --get "branch.$2.merge" || true)" == "refs/heads/$2" ]] || return 1
  for ref in origin/dev origin/main; do
    git -C "$1" rev-parse -q --verify "refs/remotes/$ref" >/dev/null || continue
    git -C "$1" merge-base --is-ancestor "refs/heads/$2" "refs/remotes/$ref" && return 0
  done
  return 1
}

for repo in "${repos[@]}"; do
  name="$(basename "$repo")"
  if ! git -C "$repo" rev-parse --git-dir >/dev/null 2>&1; then
    echo "$name: not a git repository — skipped" >&2
    failed=1
    continue
  fi
  echo "== $name"

  # Refresh origin/* for real runs; dry runs leave refs unchanged.
  # Offline is not fatal: use the last-fetched refs.
  if [[ $dry_run -eq 1 ]]; then
    echo "   (dry run — judging against last-fetched origin refs)"
  elif ! git -C "$repo" fetch --prune --quiet origin 2>/dev/null; then
    echo "   (fetch failed — judging against last-fetched origin refs)"
  fi

  if git -C "$repo" rev-parse -q --verify refs/remotes/origin/dev >/dev/null; then
    integration="dev"
  elif git -C "$repo" rev-parse -q --verify refs/remotes/origin/main >/dev/null; then
    integration="main"
  else
    echo "   no origin/dev or origin/main — skipped"
    continue
  fi

  current="$(git -C "$repo" branch --show-current)"
  freed=""   # the current branch, once --include-current has moved (or would move) off it

  if [[ $include_current -eq 1 && -n "$current" \
        && "$current" != "main" && "$current" != "dev" ]] && merged "$repo" "$current"; then
    if [[ -n "$(git -C "$repo" status --porcelain)" ]]; then
      :   # reported as "kept (checked out)" below
    elif [[ $dry_run -eq 1 ]]; then
      echo "   would switch to $integration"
      freed="$current"
    elif git -C "$repo" switch --quiet "$integration" 2>/dev/null \
         && git -C "$repo" merge --ff-only --quiet "origin/$integration" 2>/dev/null; then
      echo "   switched to $integration"
    else
      echo "   FAILED  to switch to or fast-forward $integration; skipping this repository" >&2
      failed=1
      continue
    fi
  fi

  # Branches checked out in any worktree of this clone, including this one.
  checked_out="$(git -C "$repo" worktree list --porcelain | sed -n 's|^branch refs/heads/||p')"

  while IFS= read -r branch; do
    [[ -z "$branch" || "$branch" == "main" || "$branch" == "dev" ]] && continue
    if [[ "$branch" != "$freed" ]] && printf '%s\n' "$checked_out" | grep -qxF "$branch"; then
      echo "   kept    $branch (checked out)"
    elif ! merged "$repo" "$branch"; then
      echo "   kept    $branch (not pushed, or not yet on origin/dev or origin/main)"
    elif [[ $dry_run -eq 1 ]]; then
      echo "   would delete $branch"
      pruned_total=$((pruned_total + 1))
    # -D, not -d: -d judges against the branch's upstream or HEAD, which can refuse
    # a branch whose upstream is gone. merged() above is the real safety check.
    elif git -C "$repo" branch -D --quiet "$branch" >/dev/null 2>&1; then
      echo "   deleted $branch"
      pruned_total=$((pruned_total + 1))
    else
      echo "   FAILED  to delete $branch" >&2
      failed=1
    fi
  done < <(git -C "$repo" for-each-ref --format='%(refname:short)' refs/heads)
done

if [[ $dry_run -eq 1 ]]; then
  echo "Would prune ${pruned_total} branch(es). Re-run without --dry-run to delete."
else
  echo "Pruned ${pruned_total} branch(es). Reopen one with: git switch <N-slug>"
fi
exit "$failed"
