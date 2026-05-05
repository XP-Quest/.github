#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_CHECKPOINT="${SCRIPT_DIR}/../journal/.daily-log-checkpoint"

usage() {
  cat <<EOF
Usage: $(basename "$0") [--from DATE] [--to DATE] [--checkpoint FILE]

Runs daily_git_summary.sh for each date in the given range (inclusive).
Without --from, reads the last-run date from the checkpoint file.
Without --to, defaults to yesterday.

Options:
  --from DATE         Start date (inclusive). Defaults to checkpoint date if omitted.
  --to DATE           End date (inclusive). Defaults to yesterday.
  --checkpoint FILE   Path to checkpoint file (default: journal/.daily-log-checkpoint).
                      Stores the last-run date; updated to today on completion when
                      --from was not specified explicitly.
                      Override via env: DAILY_LOG_CHECKPOINT
  -h, --help          Show this help message

Date formats accepted:
  YYYY-MM-DD       2026-04-21
  MM/DD/YYYY       04/21/2026
  DD Mon YYYY      21 Apr 2026
  "last monday"    any expression understood by GNU date -d

Examples:
  $(basename "$0")                           # resume from checkpoint to yesterday
  $(basename "$0") --from 2026-04-21        # explicit start, runs to yesterday
  $(basename "$0") --from 2026-04-21 --to 2026-04-29
EOF
}

parse_date() {
  local input="$1" label="$2"
  local result
  if ! result=$(date -d "$input" +%Y-%m-%d 2>/dev/null); then
    echo "Error: invalid $label date '$input'." >&2
    echo "Run $(basename "$0") --help for accepted date formats." >&2
    exit 1
  fi
  echo "$result"
}

FROM=""
TO=""
CHECKPOINT="${DAILY_LOG_CHECKPOINT:-$DEFAULT_CHECKPOINT}"
EXPLICIT_FROM=false
EXPLICIT_TO=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --from)       FROM="${2:-}"; EXPLICIT_FROM=true; shift 2 ;;
    --to)         TO="${2:-}"; EXPLICIT_TO=true; shift 2 ;;
    --checkpoint) CHECKPOINT="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
  esac
done

# Resolve FROM from checkpoint if not specified explicitly.
if [[ -z "$FROM" ]]; then
  if [[ -f "$CHECKPOINT" ]]; then
    FROM=$(cat "$CHECKPOINT" | tr -d '[:space:]')
    echo "Resuming from checkpoint: $FROM"
  else
    echo "Error: --from is required (no checkpoint found at $CHECKPOINT)." >&2
    echo "Run with --from DATE to set the starting date for the first run." >&2
    usage
    exit 1
  fi
fi

FROM=$(parse_date "$FROM" "--from")
TO=$(parse_date "${TO:-yesterday}" "--to")

if [[ $(date -d "$FROM" +%s) -gt $(date -d "$TO" +%s) ]]; then
  if [[ "$EXPLICIT_FROM" == true && "$EXPLICIT_TO" == true ]]; then
    echo "Error: --from ($FROM) must not be after --to ($TO)." >&2
    exit 1
  else
    echo "Nothing to process: --from ($FROM) is not before --to ($TO)."
    exit 0
  fi
fi

current="$FROM"
while [[ $(date -d "$current" +%s) -le $(date -d "$TO" +%s) ]]; do
  echo "Processing $current..."
  "$SCRIPT_DIR/daily_git_summary.sh" "$current" && echo "  done" || echo "  skipped (no commits)"
  current=$(date -d "$current + 1 day" +%Y-%m-%d)
done

# Update checkpoint to today when running in checkpoint-driven mode.
if [[ "$EXPLICIT_FROM" == false ]]; then
  today=$(date +%Y-%m-%d)
  mkdir -p "$(dirname "$CHECKPOINT")"
  echo "$today" > "$CHECKPOINT"
  echo "Checkpoint updated to $today"
fi
