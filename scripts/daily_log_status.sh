#!/usr/bin/env bash
# daily_log_status.sh: classify each date's Daily-Logs state for the xpquest-daily-log
# skill (Step 2), so the skill only opens the logs of dates that need work.
#
# Reads only; it never writes to Daily-Logs. Run it after the git summaries exist
# (historical_git_summary.sh / daily_git_summary.sh), since those create the starter logs.
#
# Usage: daily_log_status.sh FROM [TO]
#   FROM, TO are inclusive dates (anything GNU date -d accepts). TO defaults to FROM.
#
# Output: one tab-separated line per date:
#   <DATE>  daily=<state>  sred=<state>  sessions=<N>  action=<action>
#
#   daily     missing   no daily_log for the date
#             starter   daily_git_summary.sh's draft (still has the sentinel line)
#             enriched  written by the skill
#   sred      present   sred_daily_log exists
#             none      no SR&ED log, and the daily log records no SR&ED work
#             gap       no SR&ED log, but the enriched daily log's "## SR&ED Activity"
#                       section has a WP pointer bullet
#             check     no SR&ED log, and that section has text this script cannot
#                       classify; the skill reads it and decides
#   sessions  number of transcripts on THIS host with messages on the date
#   action    none        nothing to log (no daily log, no git summary, no sessions)
#             fresh       write the logs from scratch
#             skip        enriched and this host has nothing to add
#             merge       enriched and this host has session content: merge-mode check
#             sred        enriched; SR&ED log needs attention (sred=gap or check)
#             merge+sred  both of the above
#
# Exit: 0 ok, 1 usage or bad date, 2 the session digest failed.
#
# Env: OUTPUT_DIR (Daily-Logs folder), XPQ_SESSIONS_DIR (read by session_summary.py).

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
XPQUEST_ROOT="$(cd -- "${SCRIPT_DIR}/../.." && pwd)"
OUTPUT_DIR="${OUTPUT_DIR:-${XPQUEST_ROOT}/xpq-project/Daily-Logs}"
SENTINEL="Session transcripts not included"

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "Usage: $(basename "$0") FROM [TO]" >&2
  exit 1
fi

parse_date() {
  local result
  if ! result=$(date -d "$1" +%Y-%m-%d 2>/dev/null); then
    echo "Error: invalid date '$1'." >&2
    exit 1
  fi
  echo "$result"
}

FROM=$(parse_date "$1")
TO=$(parse_date "${2:-$1}")

if [[ "$FROM" > "$TO" ]]; then
  echo "Error: FROM ($FROM) must not be after TO ($TO)." >&2
  exit 1
fi

# Prints the body of the daily log's "## SR&ED Activity" section (up to the next
# heading or rule), without blank lines.
sred_section() {
  awk '
    /^## SR&ED Activity/ { in_section = 1; next }
    in_section && (/^## / || /^---/) { exit }
    in_section && NF { print }
  ' "$1"
}

# The skill writes "- **WPN** (title): ..." pointer bullets when the day has SR&ED work.
# Some enriched logs instead carry the heading with a "None. ..." explanation; that is
# not a gap.
sred_state() {
  local daily_log=$1 section
  section=$(sred_section "$daily_log")
  if [[ -z "$section" ]]; then
    echo none
  elif grep -Eq '^- \*\*(WP[1-6]|Cross-cutting)\*\*' <<< "$section"; then
    echo gap
  elif [[ "$section" == None* ]]; then
    echo none
  else
    echo check
  fi
}

current="$FROM"
while [[ ! "$current" > "$TO" ]]; do
  daily_log="${OUTPUT_DIR}/daily_log-${current}.md"
  sred_log="${OUTPUT_DIR}/sred_daily_log-${current}.md"
  summary="${OUTPUT_DIR}/github_summary-${current}.md"

  if ! digest=$(python3 "${SCRIPT_DIR}/session_summary.py" "$current"); then
    echo "Error: session_summary.py failed for $current." >&2
    exit 2
  fi
  sessions=$(grep -c '^--- .*\.jsonl$' <<< "$digest" || true)

  if [[ ! -f "$daily_log" ]]; then
    daily=missing
  elif grep -q "$SENTINEL" "$daily_log"; then
    daily=starter
  else
    daily=enriched
  fi

  if [[ -f "$sred_log" ]]; then
    sred=present
  elif [[ "$daily" == enriched ]]; then
    sred=$(sred_state "$daily_log")
  else
    sred=none
  fi

  if [[ "$daily" == enriched ]]; then
    action=skip
    (( sessions > 0 )) && action=merge
    if [[ "$sred" == gap || "$sred" == check ]]; then
      [[ "$action" == merge ]] && action="merge+sred" || action=sred
    fi
  elif [[ "$daily" == missing && ! -f "$summary" ]] && (( sessions == 0 )); then
    action=none
  else
    action=fresh
  fi

  printf '%s\tdaily=%s\tsred=%s\tsessions=%s\taction=%s\n' \
    "$current" "$daily" "$sred" "$sessions" "$action"

  current=$(date -d "$current + 1 day" +%Y-%m-%d)
done
