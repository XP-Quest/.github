#!/usr/bin/env bash
# install-hooks.sh: install xpq-org commit-msg hook into a target git repo.
#
# Usage:
#   install-hooks.sh                 # install into current working directory
#   install-hooks.sh <repo-path>     # install into specified repo
#
# Symlinks scripts/hooks/commit-msg into <repo>/.git/hooks/commit-msg so
# updates to the hook in xpq-org propagate without re-running this script.
#
# An existing non-symlink hook at the destination is backed up with a
# timestamp suffix so nothing is lost.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK_SRC="$SCRIPT_DIR/hooks/commit-msg"

target="${1:-$PWD}"
target=$(cd "$target" && pwd)

if [[ ! -f "$HOOK_SRC" ]]; then
  echo "Error: hook source not found at $HOOK_SRC" >&2
  exit 1
fi

if [[ ! -d "$target/.git" ]]; then
  echo "Error: '$target' is not a git repository (no .git directory)." >&2
  exit 1
fi

chmod +x "$HOOK_SRC"

hooks_dir="$target/.git/hooks"
mkdir -p "$hooks_dir"
dest="$hooks_dir/commit-msg"

if [[ -L "$dest" ]]; then
  rm "$dest"
elif [[ -e "$dest" ]]; then
  backup="${dest}.backup-$(date +%Y%m%d-%H%M%S)"
  mv "$dest" "$backup"
  echo "Existing commit-msg hook backed up to: $backup"
fi

ln -s "$HOOK_SRC" "$dest"
echo "Installed commit-msg hook in $target"
echo "  $dest -> $HOOK_SRC"

# Ensure '#NN:' subjects survive git's commit-msg cleanup. Git's default
# cleanup strips lines starting with core.commentChar (default '#') in
# editor mode, which would erase our enforced subject. Use ';' instead.
current_cc=$(git -C "$target" config --local --get core.commentChar 2>/dev/null || true)
if [[ -z "$current_cc" ]]; then
  git -C "$target" config --local core.commentChar ';'
  echo "Set core.commentChar=';' in $target (so '#NN:' survives cleanup)."
elif [[ "$current_cc" != ';' && "$current_cc" != '#' ]]; then
  echo "Note: core.commentChar in $target is '$current_cc'. Hook will honor it."
elif [[ "$current_cc" == '#' ]]; then
  git -C "$target" config --local core.commentChar ';'
  echo "Changed core.commentChar from '#' to ';' in $target (so '#NN:' survives cleanup)."
fi
