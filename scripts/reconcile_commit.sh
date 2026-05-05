#!/usr/bin/env bash
# reconcile_commit.sh: attach an untracked commit to a GitHub issue.
# See SR_ED_CONVENTIONS.md "Layer 3 procedure".
#
# Posts a verbose comment to <issue> referencing <sha>, then appends <sha>
# to xpq-org/journal/.reconciled so subsequent daily-log runs suppress it
# from the (untracked) section.
set -euo pipefail

usage() {
  cat <<EOF
Usage: $(basename "$0") <sha> <issue> [options]

Options:
  --repo ORG/NAME    GitHub repository (default: from origin remote of PWD)
  --message TEXT     Comment body; skip the editor
  --dry-run          Print what would happen; do not post or record
  -h, --help         Show this help

Run from inside the local checkout of the repo holding the commit.
EOF
}

SHA=""
ISSUE=""
REPO=""
MESSAGE=""
DRY_RUN=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)    REPO="${2:-}"; shift 2 ;;
    --message) MESSAGE="${2:-}"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    -*)        echo "Unknown option: $1" >&2; usage; exit 1 ;;
    *)
      if   [[ -z "$SHA"   ]]; then SHA="$1"
      elif [[ -z "$ISSUE" ]]; then ISSUE="$1"
      else echo "Unexpected positional argument: $1" >&2; exit 1
      fi
      shift ;;
  esac
done

if [[ -z "$SHA" || -z "$ISSUE" ]]; then
  usage; exit 1
fi

if [[ ! "$ISSUE" =~ ^[0-9]+$ ]]; then
  echo "Error: <issue> must be a positive integer." >&2
  exit 1
fi

if ! git rev-parse --verify "${SHA}^{commit}" >/dev/null 2>&1; then
  echo "Error: '$SHA' is not a valid commit in $(pwd)." >&2
  echo "  Run this script from inside the repo holding the commit." >&2
  exit 1
fi
SHA=$(git rev-parse --verify "${SHA}^{commit}")
SHORT_SHA="$SHA"

if [[ -z "$REPO" ]]; then
  url=$(git config --get remote.origin.url 2>/dev/null || true)
  if [[ -z "$url" ]]; then
    echo "Error: no origin remote configured and --repo not given." >&2
    exit 1
  fi
  url="${url%.git}"
  if [[ "$url" =~ github\.com[:/]([^/]+/[^/]+)$ ]]; then
    REPO="${BASH_REMATCH[1]}"
  else
    echo "Error: could not parse repo from origin URL '$url'. Use --repo." >&2
    exit 1
  fi
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RECONCILED_FILE="$(dirname "$SCRIPT_DIR")/journal/.reconciled"

if [[ ! -f "$RECONCILED_FILE" ]]; then
  echo "Error: reconciled list not found at $RECONCILED_FILE" >&2
  exit 1
fi

if grep -Eq "^${SHORT_SHA}([[:space:]]|$)" "$RECONCILED_FILE"; then
  echo "Note: $SHORT_SHA is already in .reconciled. No action taken."
  exit 0
fi

if [[ -n "$MESSAGE" ]]; then
  BODY="$MESSAGE"
else
  TMP=$(mktemp --suffix=.md)
  trap 'rm -f "$TMP"' EXIT

  COMMIT_SUBJECT=$(git log -1 --format='%s' "$SHA")
  COMMIT_DATE=$(git log -1 --format='%ai' "$SHA")
  DIFFSTAT=$(git show --stat --format= "$SHA" | sed 's/^/; /')

  cat > "$TMP" <<EOF
; Reconciling commit $SHORT_SHA to $REPO#$ISSUE
; Date:    $COMMIT_DATE
; Subject: $COMMIT_SUBJECT
;
; Diffstat:
$DIFFSTAT
;
; Write your comment below the marker. Lines above the marker are stripped.
; Aim for Rule 4 standard: what changed, why, what was ruled out, what's next.
;
--- comment body below ---
**Retroactively attached: commit \`$SHORT_SHA\`.** This commit was made before the subject conformed to the \`#NN:\` rule.

EOF

  "${EDITOR:-vi}" "$TMP"

  BODY=$(awk '/^--- comment body below ---$/{found=1; next} found' "$TMP")
  if [[ -z "$(echo "$BODY" | tr -d '[:space:]')" ]]; then
    echo "Aborted: empty comment body." >&2
    exit 1
  fi
fi

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "[dry-run] Would post to ${REPO}#${ISSUE}:"
  echo "---"
  printf '%s\n' "$BODY"
  echo "---"
  echo "[dry-run] Would append to $RECONCILED_FILE:"
  echo "  $SHORT_SHA  reconciled to ${REPO}#${ISSUE} on $(date +%Y-%m-%d)"
  exit 0
fi

if ! gh issue comment "$ISSUE" --repo "$REPO" --body "$BODY"; then
  echo "Error: failed to post comment. Not appending to .reconciled." >&2
  exit 1
fi

printf '%s  reconciled to %s#%s on %s\n' \
  "$SHORT_SHA" "$REPO" "$ISSUE" "$(date +%Y-%m-%d)" >> "$RECONCILED_FILE"

echo "Reconciled $SHORT_SHA -> ${REPO}#${ISSUE}"
