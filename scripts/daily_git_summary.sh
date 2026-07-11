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
XPQUEST_ROOT="$(cd -- "${SCRIPT_DIR}/../.." && pwd)"
DEFAULT_SEARCH_ROOT="$XPQUEST_ROOT"
SEARCH_ROOT="${SEARCH_ROOT:-$DEFAULT_SEARCH_ROOT}"
OUTPUT_DIR="${OUTPUT_DIR:-${XPQUEST_ROOT}/xpq-project/Daily-Logs}"
OUTPUT_FILE="${OUTPUT_DIR}/github_summary-${TARGET_DATE}.md"
DAILY_LOG_FILE="${OUTPUT_DIR}/daily_log-${TARGET_DATE}.md"
MEETINGS_DIR="${MEETINGS_DIR:-${XPQUEST_ROOT}/xpq-project/Meetings}"

AFTER="${TARGET_DATE} 00:00:00"
BEFORE="${TARGET_DATE} 23:59:59"

# SR&ED is determined by the issue's `sred` GitHub label (see SR_ED_CONVENTIONS.md), not by
# matching keywords in commit/issue text — text matching false-positives on routine engineering
# that happens to mention a WP-adjacent term (e.g. "pgvector" in an infra migration issue).
is_sred() {
  local repo="$1" issue="$2"
  [[ ",${issue_labels_cache["${repo}:${issue}"]-}," == *",sred,"* ]]
}

# Fold in the Time Tracker daily summary (per-project tracked hours) the XP Quest
# widget writes as $XPQUEST_SUMMARY_DIR/daily-summary-<DATE>.json. The widget may
# run on Windows (native exe) while this runs in WSL, so resolve the dir the same
# way the skill does: explicit override, then the Linux home, then /mnt/c.
DATE_FILE="daily-summary-${TARGET_DATE}.json"
summary_json=""
if [[ -n "${XPQUEST_SUMMARY_DIR:-}" && -f "${XPQUEST_SUMMARY_DIR}/${DATE_FILE}" ]]; then
  summary_json="${XPQUEST_SUMMARY_DIR}/${DATE_FILE}"
elif [[ -f "${HOME}/.xpquest/${DATE_FILE}" ]]; then
  summary_json="${HOME}/.xpquest/${DATE_FILE}"
else
  summary_json=$(ls -t /mnt/c/Users/*/.xpquest/"${DATE_FILE}" 2>/dev/null | head -1 || true)
fi

# Prettify it into a human-readable Markdown block (grouped by workstream) here,
# locally — so the daily-log skill can copy it through without parsing JSON itself.
# Days with no summary file leave this empty and time is simply omitted.
time_summary_block=""
if [[ -n "$summary_json" && -f "$summary_json" ]] && command -v jq >/dev/null 2>&1; then
  time_summary_block=$(jq -r '
    def hm($s): ($s/60|floor) as $m | "\($m/60|floor):\((($m%60)|tostring|("0"+.)[-2:]))";
    def wsname($w): {"engineering":"Engineering / R&D","sred":"SR&ED","client":"Client"}[$w] // $w;
    def rank($w): {"engineering":0,"sred":1,"client":2}[$w] // 3;
    "## Time Tracking",
    "",
    ( .projects
      | group_by(.workstream)
      | sort_by(.[0].workstream | rank(.))
      | .[]
      | ( "### " + wsname(.[0].workstream) ),
        "",
        ( .[] | "- **[\(.code)] \(.name)** — \(hm(.seconds))"
                + (if (.description // "") != "" then " — \(.description)" else "" end)
                + (if (.client // "") != "" then " (\(.client))" else "" end) ),
        ""
    ),
    ( "**Total tracked:** " + hm(([.projects[].seconds] | add) // 0) )
  ' "$summary_json" 2>/dev/null || true)
fi

# Cache issue titles and labels together (one `gh` call each): key="<org/repo>:<issue>".
# issue_labels_cache stores a comma-joined, comma-bounded label list (",label1,label2,") so
# is_sred() can substring-match a single label name without false-matching a prefix/suffix.
declare -A issue_title_cache=()
declare -A issue_labels_cache=()

fetch_issue_meta() {
  local repo="$1" issue="$2"
  local key="${repo}:${issue}"
  if [[ -n "${issue_title_cache[$key]+set}" ]]; then
    return
  fi
  local title="" labels=""
  if command -v gh >/dev/null 2>&1; then
    local json
    json=$(gh issue view "$issue" --repo "$repo" --json title,labels 2>/dev/null || true)
    if [[ -n "$json" ]]; then
      title=$(jq -r '.title' <<<"$json" 2>/dev/null || true)
      labels=$(jq -r '[.labels[].name] | join(",")' <<<"$json" 2>/dev/null || true)
    fi
  fi
  [[ -z "$title" ]] && title="(title unavailable)"
  issue_title_cache["$key"]="$title"
  issue_labels_cache["$key"]="$labels"
}

fetch_issue_title() {
  local repo="$1" issue="$2"
  fetch_issue_meta "$repo" "$issue"
  printf '%s' "${issue_title_cache["${repo}:${issue}"]}"
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
declare -a eng_log_lines=()
declare -a sred_log_lines=()

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

    sred_hit=1
    if [[ -n "$repo_id" ]]; then
      title=$(fetch_issue_title "$repo_id" "$issue")
      issue_link="[#${issue}: ${title}](https://github.com/${repo_id}/issues/${issue})"
      is_sred "$repo_id" "$issue" && sred_hit=0
    else
      title="(no remote configured)"
      issue_link="#${issue}: ${title}"
      # No remote means no `gh` lookup is possible; err conservative (engineering, not SR&ED)
      # per CLAUDE.md §4 — routine engineering wrongly left untagged is a smaller risk than
      # SR&ED wrongly claimed.
    fi
    section+="- ${issue_link}"$'\n'
    section+="  ${sha}: ${rendered_subject}"$'\n'

    if [[ $sred_hit -eq 0 ]]; then
      sred_log_lines+=( "- **${repo_name}** ${issue_link}" )
      sred_log_lines+=( "  - \`${sha}\`: ${rendered_subject}" )
    else
      eng_log_lines+=( "- **${repo_name}** ${issue_link}" )
      eng_log_lines+=( "  - \`${sha}\`: ${rendered_subject}" )
    fi
  done <<< "$commits"

  if [[ -n "$section" ]]; then
    sections+=( "## ${repo_name}"$'\n\n'"${section}" )
  fi
done < <(find "$SEARCH_ROOT" -maxdepth 3 -name ".git" -type d | sort)

# Gather meeting notes
declare -a meeting_lines=()
if [[ -d "$MEETINGS_DIR" ]]; then
  while IFS= read -r f; do
    local_category=$(grep -m1 '^category:' "$f" 2>/dev/null | sed 's/^category:[[:space:]]*//' || true)
    local_topic=$(grep -m1 '^topic:' "$f" 2>/dev/null | sed 's/^topic:[[:space:]]*//' || true)
    local_attendees=$(grep -m1 '^attendees:' "$f" 2>/dev/null | sed 's/^attendees:[[:space:]]*//' || true)
    [[ -z "$local_topic" ]] && local_topic="$(basename "$f" .md)"
    meeting_lines+=("- ${local_topic}${local_attendees:+ (with ${local_attendees})}${local_category:+ [${local_category}]}")
  done < <(find "$MEETINGS_DIR" -maxdepth 1 -name "${TARGET_DATE}-*.md" 2>/dev/null | sort)
fi

if [[ ${#sections[@]} -eq 0 && ${#untracked_lines[@]} -eq 0 && ${#meeting_lines[@]} -eq 0 && -z "$time_summary_block" ]]; then
  exit 0
fi

mkdir -p "$OUTPUT_DIR"

if [[ ${#sections[@]} -gt 0 || ${#untracked_lines[@]} -gt 0 || -n "$time_summary_block" ]]; then
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
      echo "Attribute each by amending the commit subject or noting the SHA on the relevant issue."
      echo ""
      for line in "${untracked_lines[@]}"; do
        echo "$line"
      done
      echo ""
    fi
    if [[ -n "$time_summary_block" ]]; then
      echo "$time_summary_block"
      echo ""
    fi
  } > "$OUTPUT_FILE"
fi

{
  echo "# XP Quest — Daily Log — ${TARGET_DATE}"
  echo ""
  if [[ ${#eng_log_lines[@]} -gt 0 ]]; then
    echo "## Engineering / R&D"
    echo ""
    for line in "${eng_log_lines[@]}"; do
      echo "$line"
    done
    echo ""
  fi
  if [[ ${#sred_log_lines[@]} -gt 0 ]]; then
    echo "## SR&ED Activity"
    echo ""
    for line in "${sred_log_lines[@]}"; do
      echo "$line"
    done
    echo ""
  fi
  if [[ ${#untracked_lines[@]} -gt 0 ]]; then
    echo "## Untracked Commits"
    echo ""
    for line in "${untracked_lines[@]}"; do
      echo "$line"
    done
    echo ""
  fi
  if [[ ${#meeting_lines[@]} -gt 0 ]]; then
    echo "## Meetings"
    echo ""
    for line in "${meeting_lines[@]}"; do
      echo "$line"
    done
    echo ""
  fi
  echo "---"
  echo "*Session transcripts not included — run \`xpquest-daily-log\` skill manually if needed.*"
} > "$DAILY_LOG_FILE"
