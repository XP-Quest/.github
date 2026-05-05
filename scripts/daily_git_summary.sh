#!/usr/bin/env bash
# daily_git_summary.sh: produce a daily commit summary across XPQ repos,
# grouped by GitHub issue. See SR_ED_CONVENTIONS.md "Issue-driven commit
# workflow" for the parsing contract.
#
# Usage: daily_git_summary.sh [YYYY-MM-DD]
# If no date is given, defaults to today.

set -euo pipefail

if [[ $# -gt 0 ]]; then
  TARGET_DATE="$1"
  if ! date -d "$TARGET_DATE" +%Y-%m-%d &>/dev/null; then
    echo "Error: invalid date '$TARGET_DATE'. Expected format: YYYY-MM-DD" >&2
    exit 1
  fi
else
  TARGET_DATE=$(date +%Y-%m-%d)
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_SEARCH_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
SEARCH_ROOT="${SEARCH_ROOT:-$DEFAULT_SEARCH_ROOT}"
OUTPUT_DIR="${OUTPUT_DIR:-${DEFAULT_SEARCH_ROOT}/Daily Logs}"
OUTPUT_FILE="${OUTPUT_DIR}/github_summary-${TARGET_DATE}.md"
RECONCILED_FILE="${RECONCILED_FILE:-${SEARCH_ROOT}/xpq-org/journal/.reconciled}"

AFTER="${TARGET_DATE} 00:00:00"
BEFORE="${TARGET_DATE} 23:59:59"

# Load reconciled SHAs (Layer 3 skip list).
declare -A reconciled=()
if [[ -f "$RECONCILED_FILE" ]]; then
  while IFS= read -r line; do
    [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
    sha=$(awk '{print $1}' <<< "$line")
    [[ -n "$sha" ]] && reconciled["$sha"]=1
  done < "$RECONCILED_FILE"
fi

# Cache issue titles: key="<org/repo>:<issue>".
declare -A issue_title_cache=()

fetch_issue_title() {
  local repo="$1" issue="$2"
  local key="${repo}:${issue}"
  if [[ -n "${issue_title_cache[$key]+set}" ]]; then
    printf '%s' "${issue_title_cache[$key]}"
    return
  fi
  local title=""
  if command -v gh >/dev/null 2>&1; then
    title=$(gh issue view "$issue" --repo "$repo" --json title --jq '.title' 2>/dev/null || true)
  fi
  [[ -z "$title" ]] && title="(title unavailable)"
  issue_title_cache["$key"]="$title"
  printf '%s' "$title"
}

# Extract org/repo from origin URL.
repo_identifier() {
  local dir="$1"
  local url
  url=$(git -C "$dir" config --get remote.origin.url 2>/dev/null || true)
  [[ -z "$url" ]] && { echo ""; return; }
  url="${url%.git}"
  if [[ "$url" =~ github\.com[:/]([^/]+/[^/]+)$ ]]; then
    echo "${BASH_REMATCH[1]}"
  else
    echo ""
  fi
}

# Layer 2 fallback: find an <issue>-<slug> branch containing this SHA.
# Choose deterministically when a commit is reachable from multiple issue
# branches: prefer origin/<issue>-* branches, then local <issue>-* branches,
# and break ties lexicographically by branch name.
issue_from_branches() {
  local dir="$1" sha="$2"
  local branches
  local b normalized issue rank
  local best_issue="" best_branch="" best_rank=99

  branches=$(git -C "$dir" branch --all --contains "$sha" --format='%(refname:short)' 2>/dev/null || true)
  while IFS= read -r b; do
    [[ -z "$b" ]] && continue

    rank=99
    normalized="$b"
    if [[ "$b" == origin/* ]]; then
      rank=0
      normalized="${b#origin/}"
    elif [[ "$b" != remotes/* ]]; then
      rank=1
    fi

    if [[ "$normalized" =~ ^([0-9]+)- ]]; then
      issue="${BASH_REMATCH[1]}"
      if (( rank < best_rank )) || [[ $rank -eq $best_rank && ( -z "$best_branch" || "$normalized" < "$best_branch" ) ]]; then
        best_rank=$rank
        best_branch="$normalized"
        best_issue="$issue"
      fi
    fi
  done <<< "$branches"

  echo "$best_issue"
}

declare -a sections=()
declare -a untracked_lines=()

while IFS= read -r git_dir; do
  repo_dir="${git_dir%/.git}"
  repo_name=$(basename "$repo_dir")
  repo_id=$(repo_identifier "$repo_dir")

  commits=$(git -C "$repo_dir" log \
    --after="$AFTER" --before="$BEFORE" \
    --branches --tags --remotes --no-merges \
    --format='%h%x09%s' 2>/dev/null || true)
  [[ -z "$commits" ]] && continue

  section=""
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    sha="${line%%	*}"
    subject="${line#*	}"

    [[ -n "${reconciled[$sha]+set}" ]] && continue

    issue=""
    rendered_subject="$subject"
    if [[ "$subject" =~ ^#([0-9]+):[[:space:]]+(.*)$ ]]; then
      issue="${BASH_REMATCH[1]}"
      rendered_subject="${BASH_REMATCH[2]}"
    else
      issue=$(issue_from_branches "$repo_dir" "$sha")
    fi

    if [[ -z "$issue" ]]; then
      untracked_lines+=( "- **${repo_name}** \`${sha}\`: ${subject}" )
      continue
    fi

    if [[ -n "$repo_id" ]]; then
      title=$(fetch_issue_title "$repo_id" "$issue")
    else
      title="(no remote configured)"
    fi
    section+="- #${issue}: ${title}"$'\n'
    section+="  ${sha}: ${rendered_subject}"$'\n'
  done <<< "$commits"

  if [[ -n "$section" ]]; then
    sections+=( "## ${repo_name}"$'\n\n'"${section}" )
  fi
done < <(find "$SEARCH_ROOT" -maxdepth 3 -name ".git" -type d | sort)

if [[ ${#sections[@]} -eq 0 && ${#untracked_lines[@]} -eq 0 ]]; then
  exit 0
fi

mkdir -p "$OUTPUT_DIR"
{
  echo "# XP Quest - GitHub Commit Summary — ${TARGET_DATE}"
  echo ""
  for section in "${sections[@]}"; do
    echo "$section"
  done
  if [[ ${#untracked_lines[@]} -gt 0 ]]; then
    echo "## (untracked)"
    echo ""
    echo "Commits with no \`#NN:\` subject prefix and no \`<issue>-\` branch fallback."
    echo "For each commit, first \`cd\` into the repo shown on that line (the repo that contains the SHA)."
    echo "Then run \`xpq-org/scripts/reconcile_commit.sh <sha> <issue>\` from there."
    echo ""
    for line in "${untracked_lines[@]}"; do
      echo "$line"
    done
    echo ""
  fi
} > "$OUTPUT_FILE"
