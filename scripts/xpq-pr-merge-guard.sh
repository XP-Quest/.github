#!/usr/bin/env bash
# xpq-pr-merge-guard.sh: PreToolUse hook — blocks Claude from running gh pr merge.
#
# PRs must be merged by the user, not autonomously by Claude. This prevents
# Claude from self-merging to dev or main even in permissive permission modes
# where a broad gh pr wildcard exists in the allow list.

set -euo pipefail

input=$(cat)

command=$(printf '%s' "$input" \
  | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(d.get('tool_input', {}).get('command', ''))
" 2>/dev/null || true)

# Fixed-string match anywhere in the command — intentionally broad so wrapping
# (e.g. bash -c "gh pr merge 123") does not bypass the guard.
if echo "$command" | grep -qF 'gh pr merge'; then
  python3 -c "
import sys, json
cmd = sys.argv[1]
print(json.dumps({
    'hookSpecificOutput': {
        'hookEventName': 'PreToolUse',
        'permissionDecision': 'deny',
        'permissionDecisionReason': (
            'Claude is not permitted to merge PRs autonomously. '
            'PRs must be reviewed and merged by you — either on GitHub '
            'or by explicitly running the command yourself.\n\nBlocked command: ' + cmd
        )
    }
}))
" "$command"
fi
