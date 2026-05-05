#!/usr/bin/env bash
# xpq-time.sh: minimalist SR&ED time tracker.
#
# Usage:
#   xpq-time.sh start <issue> [--repo ORG/REPO]
#   xpq-time.sh stop
#   xpq-time.sh status
#
# Appends to journal/.time-log.csv. Commit that file to git — the commit
# timestamp is contemporaneous evidence for CRA.

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
JOURNAL_DIR="${JOURNAL_DIR:-${SCRIPT_DIR}/../journal}"
TIME_LOG="${JOURNAL_DIR}/.time-log.csv"
ACTIVE_FILE="${JOURNAL_DIR}/.time-active"

# Default repo derived from xpq-org's sibling repos; override with --repo.
DEFAULT_REPO=""

usage() {
  cat <<EOF
Usage: $(basename "$0") <command> [options]

Commands:
  start <issue> [--repo ORG/REPO]  Start timing an SR&ED issue.
  stop                              Stop the current timer and record hours.
  status                            Show the active timer, if any.

Options:
  --repo ORG/REPO   GitHub repo for issue lookup (e.g. XP-Quest/xpq-api).
                    Auto-detected from issue labels when omitted.
  -h, --help        Show this help message

Time log: $TIME_LOG
EOF
}

resolve_wp() {
  local issue="$1" repo="$2"
  local wp=""
  if [[ -n "$repo" ]] && command -v gh >/dev/null 2>&1; then
    wp=$(gh issue view "$issue" --repo "$repo" --json labels \
      --jq '.labels[].name | select(startswith("wp"))' 2>/dev/null | head -1 || true)
  fi
  echo "${wp:-unknown}"
}

cmd_start() {
  local issue="" repo="$DEFAULT_REPO"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --repo) repo="${2:-}"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      -*) echo "Unknown option: $1" >&2; exit 1 ;;
      *)  if [[ -z "$issue" ]]; then
            issue="$1"
          else
            echo "Unexpected argument: $1" >&2; exit 1
          fi
          shift ;;
    esac
  done

  if [[ -z "$issue" ]]; then
    echo "Error: issue number required." >&2
    echo "Usage: $(basename "$0") start <issue> [--repo ORG/REPO]" >&2
    exit 1
  fi
  issue="${issue#\#}"  # strip leading # if provided

  if [[ -f "$ACTIVE_FILE" ]]; then
    active=$(cat "$ACTIVE_FILE")
    echo "Error: timer already running — stop it first." >&2
    echo "  $active" >&2
    exit 1
  fi

  local wp
  wp=$(resolve_wp "$issue" "$repo")

  local now
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  local date_part
  date_part=$(date -d "$now" +%Y-%m-%d)

  mkdir -p "$JOURNAL_DIR"
  printf '%s\t%s\t%s\t%s\t%s\n' "$now" "start" "$issue" "${repo:-}" "$wp" > "$ACTIVE_FILE"

  echo "Started #${issue} (${wp}) at ${now}"
  [[ -n "$repo" ]] && echo "  repo: $repo"
}

cmd_stop() {
  if [[ ! -f "$ACTIVE_FILE" ]]; then
    echo "No active timer." >&2
    exit 1
  fi

  local active_line
  active_line=$(cat "$ACTIVE_FILE")
  local start_ts issue repo wp
  start_ts=$(awk -F'\t' '{print $1}' <<< "$active_line")
  issue=$(awk   -F'\t' '{print $3}' <<< "$active_line")
  repo=$(awk    -F'\t' '{print $4}' <<< "$active_line")
  wp=$(awk      -F'\t' '{print $5}' <<< "$active_line")

  local now
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  local start_epoch end_epoch elapsed_min hours
  start_epoch=$(date -d "$start_ts" +%s)
  end_epoch=$(date -d "$now" +%s)
  elapsed_min=$(( (end_epoch - start_epoch) / 60 ))
  hours=$(awk "BEGIN { printf \"%.2f\", $elapsed_min / 60 }")

  local date_part
  date_part=$(date -d "$start_ts" +%Y-%m-%d)

  mkdir -p "$JOURNAL_DIR"
  if [[ ! -f "$TIME_LOG" ]]; then
    echo "date	issue	repo	wp	start	stop	hours" > "$TIME_LOG"
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$date_part" "$issue" "$repo" "$wp" "$start_ts" "$now" "$hours" >> "$TIME_LOG"

  rm "$ACTIVE_FILE"
  echo "Stopped #${issue} — ${hours}h (${elapsed_min} min)"
  echo "  Logged to: $TIME_LOG"
}

cmd_status() {
  if [[ ! -f "$ACTIVE_FILE" ]]; then
    echo "No active timer."
    return
  fi
  local active_line
  active_line=$(cat "$ACTIVE_FILE")
  local start_ts issue wp
  start_ts=$(awk -F'\t' '{print $1}' <<< "$active_line")
  issue=$(awk    -F'\t' '{print $3}' <<< "$active_line")
  wp=$(awk       -F'\t' '{print $5}' <<< "$active_line")

  local now elapsed_min
  now=$(date -u +%s)
  start_epoch=$(date -d "$start_ts" +%s)
  elapsed_min=$(( (now - start_epoch) / 60 ))

  echo "Active: #${issue} (${wp}), running ${elapsed_min} min since ${start_ts}"
}

if [[ $# -eq 0 ]]; then
  usage
  exit 1
fi

case "$1" in
  start)  shift; cmd_start "$@" ;;
  stop)   shift; cmd_stop ;;
  status) shift; cmd_status ;;
  -h|--help) usage; exit 0 ;;
  *) echo "Unknown command: $1" >&2; usage; exit 1 ;;
esac
