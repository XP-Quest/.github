#!/usr/bin/env bash
# xpq-branch-guard.sh: PreToolUse hook — blocks Write/Edit when the current git branch
# does not follow the issue-branch convention (<N>-<slug>).
#
# Enforces: all code changes must be traceable to a GitHub issue via branch name.
# Exceptions: files outside any git repository (workspace config, skill files, etc.).

set -euo pipefail

[[ "$PWD" == /home/rcoe/xpquest* ]] || exit 0

input=$(cat)

file_path=$(printf '%s' "$input" \
  | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(d.get('tool_input', {}).get('file_path', ''))
" 2>/dev/null || true)

[[ -z "$file_path" ]] && exit 0

# Resolve the directory containing the file (it may not exist yet for Write)
file_dir=$(dirname "$file_path")
git_root=$(git -C "$file_dir" rev-parse --show-toplevel 2>/dev/null || true)

# Not inside any git repo — allow (workspace-level files, ~/.claude/*, etc.)
[[ -z "$git_root" ]] && exit 0

branch=$(git -C "$git_root" branch --show-current 2>/dev/null || true)

# Detached HEAD (rebase, cherry-pick, bisect) — allow; git enforces state separately
[[ -z "$branch" ]] && exit 0

# Valid issue branch: starts with one or more digits followed by a hyphen
if [[ "$branch" =~ ^[0-9]+-[a-zA-Z0-9_-]+ ]]; then
  exit 0
fi

repo_name=$(basename "$git_root")
printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Branch '\''%s'\'' in %s is not an issue branch. Switch to a branch named <N>-<slug> before editing files.\\n\\nTo create one:\\n  gh issue create   # or use an existing issue number\\n  git checkout -b <N>-<slug>"}}\n' \
  "$branch" "$repo_name"
