#!/usr/bin/env bash
# xpq-org-main-update.sh: fast-forward the main-only clone the daily-log skill
# runs from, keeping its working tree read-only the rest of the time.
#
# ~/xpquest/.xpq-org-main (#57) produces claim evidence, so it must stay
# identical to reviewed main. The working tree (files and directories, not
# .git/) is kept without write permission: read-only files block edits,
# read-only directories block creating, deleting and renaming files, which
# also stops editors that save via write-temp-and-rename. Git needs those
# directories writable to check out new content, so a plain `git pull` fails
# on a locked clone. This script is the update path: unlock, fast-forward,
# relock, with the relock running even when the pull fails.
#
# This guards against accidents, not intent: the owner can always chmod back.
#
# Usage: xpq-org-main-update.sh [--lock] [CLONE]
#
#   CLONE    the clone to manage (default ~/xpquest/.xpq-org-main)
#   --lock   only lock (one-time setup per machine); no pull
#
# Exit: 0 on success, 1 if the pull failed (the clone is still relocked),
# 2 on bad usage or if CLONE is not a git clone on main.

# The whole script runs from inside main(), which bash parses completely before
# running. The pull can replace this very file, and bash reads a script
# incrementally as it runs. Git currently swaps in a new file (new inode) rather
# than rewriting in place, so the running copy is safe anyway. This makes it not
# depend on that.
main() {
  set -euo pipefail

  local clone="${HOME}/xpquest/.xpq-org-main"
  local lock_only=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --lock)    lock_only=1; shift ;;
      -h|--help) sed -n '/^# Usage:/,/^# Exit:/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; return 0 ;;
      -*) echo "Unknown argument: $1" >&2; return 2 ;;
      *)  clone="$1"; shift ;;
    esac
  done

  clone="${clone%/}"
  if [[ ! -d "$clone/.git" ]]; then
    echo "Error: '${clone}' is not a git clone" >&2
    return 2
  fi
  local branch
  branch="$(git -C "$clone" branch --show-current)"
  if [[ "$branch" != "main" ]]; then
    echo "Error: '${clone}' is on '${branch}', not main" >&2
    return 2
  fi

  if [[ $lock_only -eq 1 ]]; then
    set_writable "$clone" a-w
    echo "Locked ${clone}"
    return 0
  fi

  set_writable "$clone" u+w
  # Relock however the pull ends, including an interrupt.
  trap 'set_writable "'"$clone"'" a-w' EXIT
  if git -C "$clone" pull --ff-only --quiet; then
    echo "Updated ${clone} to $(git -C "$clone" rev-parse --short HEAD)"
    return 0
  fi
  echo "Pull failed; ${clone} left at $(git -C "$clone" rev-parse --short HEAD) and relocked" >&2
  return 1
}

# set_writable <clone> <mode>: chmod everything in the working tree except .git/.
set_writable() {
  find "$1" -path "$1/.git" -prune -o -exec chmod "$2" {} +
}

main "$@"; exit
