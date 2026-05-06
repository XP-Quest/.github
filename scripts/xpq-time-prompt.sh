#!/usr/bin/env bash
# xpq-time-prompt.sh: PostToolUse hook — reminds about SR&ED time tracking
# on branch creation and PR creation.
# Outputs a systemMessage JSON so Claude surfaces the prompt to the user.

set -euo pipefail

# Only fire within XPQuest repos.
[[ "$PWD" == /home/rcoe/xpquest* ]] || exit 0

input=$(cat)
cmd=$(printf '%s' "$input" \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('tool_input',{}).get('command',''))" \
  2>/dev/null || true)

# Branch creation: git checkout -b N-slug or git switch -c N-slug
if printf '%s' "$cmd" | grep -qE 'git (checkout -b|switch -c) [0-9]+-'; then
  branch=$(printf '%s' "$cmd" | grep -oE '[0-9]+-[a-zA-Z0-9_-]+' | head -1)
  issue=$(printf '%s' "$branch" | grep -oE '^[0-9]+')
  printf '{"systemMessage": "⏱  Start time tracking for issue #%s:\\n   xpq-org/scripts/xpq-time.sh start %s"}\n' \
    "$issue" "$issue"
  exit 0
fi

# PR creation
if printf '%s' "$cmd" | grep -qE '^gh pr create'; then
  printf '{"systemMessage": "⏱  Stop time tracking before merging:\\n   xpq-org/scripts/xpq-time.sh stop"}\n'
  exit 0
fi
