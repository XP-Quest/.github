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

# Identify this machine for cross-host Time Tracking merge (see below). Robin runs
# antman and flash, never simultaneously, and neither the Tracker JSON nor Claude
# session transcripts are synced between them (see XP-Quest/.github#41) — the
# shared OneDrive Daily-Logs output is the only thing both machines see, so it is
# also where their per-host contributions get reconciled. Override with
# XPQUEST_HOST_ID if a machine's `hostname` ever isn't a stable/desired label.
HOST_ID="${XPQUEST_HOST_ID:-$(hostname 2>/dev/null || true)}"
HOST_ID=$(printf '%s' "${HOST_ID:-unknown-host}" | tr '[:upper:]' '[:lower:]')

# Prettify the Time Tracker data into a human-readable Markdown block (grouped by
# workstream) here, locally — so the daily-log skill can copy it through without
# parsing JSON itself. Days with no summary file anywhere leave this empty and
# time is simply omitted.
#
# Cross-host merge: OUTPUT_FILE lives in the shared OneDrive Daily-Logs folder, so
# a prior run (from either machine) may already have written a '## Time Tracking'
# block for this date. Re-derive the per-project state from that block's hidden
# `tracker-state` comment (code+name -> {..., by: {host: seconds}}), fold in this
# host's current projects (replacing only this host's own prior contribution per
# project, which is what keeps a same-host re-run idempotent), and re-render. The
# visible block stays organized purely by workstream/project — never by machine —
# per Robin's instruction that merged content lives in the same sections rather
# than being partitioned by device; only the invisible state comment tracks host
# attribution, and it is never shown to the skill or to Robin as a rendered line.
existing_tracker_state="{}"
if [[ -f "$OUTPUT_FILE" ]]; then
  extracted=$(sed -n '/<!-- tracker-state$/,/^tracker-state -->/p' "$OUTPUT_FILE" | sed '1d;$d')
  if [[ -n "$extracted" ]] && command -v jq >/dev/null 2>&1 && echo "$extracted" | jq empty >/dev/null 2>&1; then
    existing_tracker_state="$extracted"
  fi
fi

local_projects="[]"
if [[ -n "$summary_json" && -f "$summary_json" ]] && command -v jq >/dev/null 2>&1; then
  local_projects=$(jq -c '.projects // []' "$summary_json" 2>/dev/null || echo "[]")
fi

time_summary_block=""
if command -v jq >/dev/null 2>&1; then
  merged_tracker_state=$(jq -c -n \
    --argjson existing "$existing_tracker_state" \
    --argjson local "$local_projects" \
    --arg host "$HOST_ID" '
    reduce ($local[]) as $p ($existing;
      .[$p.code][$p.name] = {
        code: $p.code,
        name: $p.name,
        workstream: $p.workstream,
        description: ($p.description // ""),
        client: ($p.client // ""),
        by: (((.[$p.code][$p.name].by) // {}) + {($host): $p.seconds})
      }
    )
  ' 2>/dev/null || echo "$existing_tracker_state")

  time_summary_block=$(jq -r -n --argjson state "$merged_tracker_state" '
    def hm($s): ($s/60|floor) as $m | "\($m/60|floor):\((($m%60)|tostring|("0"+.)[-2:]))";
    def wsname($w): {"engineering":"Engineering / R&D","sred":"SR&ED","client":"Client"}[$w] // $w;
    def rank($w): {"engineering":0,"sred":1,"client":2}[$w] // 3;
    ([$state[][]]) as $entries |
    if ($entries | length) == 0 then empty else
    "## Time Tracking",
    "",
    ( $entries
      | group_by(.workstream)
      | sort_by(.[0].workstream | rank(.))
      | .[]
      | ( "### " + wsname(.[0].workstream) ),
        "",
        ( sort_by(.code, .name)[]
          | . + {total: ([.by[]] | add)}
          | "- **[\(.code)] \(.name)** — \(hm(.total))"
                + (if .description != "" then " — \(.description)" else "" end)
                + (if .client != "" then " (\(.client))" else "" end) ),
        ""
    ),
    ( "**Total tracked:** " + hm(($entries | map([.by[]] | add) | add) // 0) ),
    "",
    "<!-- tracker-state",
    ($state | tostring),
    "tracker-state -->"
    end
  ' 2>/dev/null || true)
fi

# Cache issue titles and labels together (one `gh` call each): key="<org/repo>:<issue>".
# issue_labels_cache stores a comma-joined label list ("label1,label2"); is_sred() adds
# bounding commas before substring-matching so a label name never matches a prefix/suffix
# of another label.
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
    # gh's built-in --jq (no external jq dependency). Two-line output: title, then labels —
    # safe to split on newline because GitHub issue titles cannot contain newlines.
    local meta
    meta=$(gh issue view "$issue" --repo "$repo" --json title,labels \
      --jq '.title, ([.labels[].name] | join(","))' 2>/dev/null || true)
    if [[ -n "$meta" ]]; then
      title="${meta%%$'\n'*}"
      labels="${meta#*$'\n'}"
      [[ "$labels" == "$meta" ]] && labels=""  # no second line (defensive)
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

# DAILY_LOG_FILE starts life as this script's own commit-only draft (marked with
# the "Session transcripts not included" sentinel below) and is later replaced by
# the xpquest-daily-log skill's fully enriched version, which folds in session
# content, SR&ED narrative, etc. and drops the sentinel. Because DAILY_LOG_FILE
# also lives in the shared OneDrive Daily-Logs folder, a second machine calling
# this script for the same date (e.g. via historical_git_summary.sh advancing its
# own checkpoint) must never regenerate the draft over an already-enriched file —
# that would silently discard everything the skill added. Only (re)write the
# draft while the file is still in draft form (missing, or still carrying the
# sentinel); once enriched, this script leaves it alone.
if [[ ! -f "$DAILY_LOG_FILE" ]] || grep -q "Session transcripts not included" "$DAILY_LOG_FILE"; then
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
fi
