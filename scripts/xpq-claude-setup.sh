#!/usr/bin/env bash
# xpq-claude-setup.sh: per-machine Claude Code setup for the XP Quest workspace.
#
# Run once on each machine (flash, antman, any new one). Idempotent; every file it changes
# is backed up next to itself as <file>.bak-<timestamp> first.
#
#   1. Installs the two guards as USER-level hooks (~/.claude/settings.json), so they load
#      whatever directory a session is launched from. The merge guard is wrapped so it only
#      runs for sessions under the workspace; the branch guard already scopes itself.
#   2. Adds built-in permissions.deny rules: gh pr merge, and local Quarkus native builds.
#      Deny beats any allow rule and applies in every repo on the machine.
#   3. Removes allow rules that defeat the guards (gh pr *, bash *, python3 *, sh *, native
#      builds) from every settings.local.json in the workspace.
#   4. Disables the claude.ai-synced plugins that are not used here.
#
# Usage: xpq-claude-setup.sh [--dry-run] [--keep-plugins] [--drop-workspace-hooks]
#   --dry-run               print what would change; write nothing
#   --keep-plugins          skip step 4
#   --drop-workspace-hooks  also remove the hooks block from the shared workspace
#                           settings.json. That file is shared by every machine through
#                           OneDrive, so pass this only after ALL machines have run this
#                           script; until then a machine that has not would lose its guards.
#
# Env: XPQ_HOME (default ~/xpquest), XPQ_PLUGINS (space-separated plugin ids to disable).

set -euo pipefail

XPQ="${XPQ_HOME:-$HOME/xpquest}"
USER_SETTINGS="$HOME/.claude/settings.json"
WORKSPACE_SETTINGS="$XPQ/.claude/settings.json"
PLUGINS="${XPQ_PLUGINS:-operations@synced productivity@synced product-management@synced}"
STAMP=$(date +%Y%m%d-%H%M%S)

DRY=0 KEEP_PLUGINS=0 DROP_WS_HOOKS=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY=1 ;;
    --keep-plugins) KEEP_PLUGINS=1 ;;
    --drop-workspace-hooks) DROP_WS_HOOKS=1 ;;
    *) echo "Unknown option: $arg" >&2; exit 2 ;;
  esac
done

command -v jq >/dev/null || { echo "jq is required (sudo apt install jq)" >&2; exit 2; }

BRANCH_GUARD="$XPQ/xpq-org/scripts/xpq-branch-guard.sh"
MERGE_GUARD="$XPQ/xpq-org/scripts/xpq-pr-merge-guard.sh"
for f in "$BRANCH_GUARD" "$MERGE_GUARD"; do
  [[ -f "$f" ]] || { echo "Missing guard script: $f (clone xpq-org first)" >&2; exit 2; }
done

BRANCH_CMD="bash $BRANCH_GUARD"
MERGE_CMD="case \"\$PWD\" in $XPQ|$XPQ/*) exec bash $MERGE_GUARD ;; esac"

DENY='[
  "Bash(gh pr merge)",
  "Bash(gh pr merge *)",
  "Bash(*mvn* -Dnative*)",
  "Bash(*mvn* -Pnative*)",
  "Bash(*quarkus build*--native*)"
]'

# Applies a jq filter to a JSON file: prints a diff, backs up and writes unless --dry-run.
apply() {
  local file=$1; shift
  local new
  new=$(jq "$@" "$file")
  if [[ "$new" == "$(jq . "$file")" ]]; then
    echo "  unchanged: $file"
    return
  fi
  diff <(jq . "$file") <(printf '%s\n' "$new") | sed 's/^/    /' || true
  if (( DRY )); then
    echo "  would update: $file"
  else
    cp -p "$file" "$file.bak-$STAMP"
    # Write through the path so a symlinked settings file stays a symlink.
    printf '%s\n' "$new" > "$file"
    echo "  updated: $file (backup: $file.bak-$STAMP)"
  fi
}

echo "1+2. User-level hooks and deny rules"
mkdir -p "$(dirname "$USER_SETTINGS")"
[[ -f "$USER_SETTINGS" ]] || { (( DRY )) || echo '{}' > "$USER_SETTINGS"; }
if [[ -f "$USER_SETTINGS" ]]; then
  apply "$USER_SETTINGS" \
    --arg branch "$BRANCH_CMD" --arg merge "$MERGE_CMD" --arg mguard "$MERGE_GUARD" \
    --arg bguard "$BRANCH_GUARD" --argjson deny "$DENY" '
    def entry($m; $c): {matcher: $m, hooks: [{type: "command", command: $c}]};
    # Drop any earlier entry for either guard, then add the current ones.
    .hooks.PreToolUse = (
      [ (.hooks.PreToolUse // [])[]
        | select(any(.hooks[]?; (.command // "") | (contains($mguard) or contains($bguard))) | not) ]
      + [ entry("Write|Edit"; $branch), entry("Bash"; $merge) ] )
    | .permissions.deny = (((.permissions.deny // []) + $deny) | unique)'
else
  echo "  would create: $USER_SETTINGS"
fi

echo "3. Allow rules that defeat the guards"
shopt -s nullglob
for f in "$XPQ/.claude/settings.local.json" "$XPQ"/*/.claude/settings.local.json \
         "$HOME/.claude/settings.local.json"; do
  [[ -f "$f" ]] || continue
  apply "$f" '
    if (.permissions.allow | type) == "array" then
      .permissions.allow |= map(select(
        (test("^Bash\\((gh pr( merge| create --base main)?|bash|sh|python3?)( \\*|:\\*)?\\)$")
         or test("^Bash\\(gh pr (merge|create --base main)")
         or test("-[DP]native")) | not))
    else . end'
done

if (( DROP_WS_HOOKS )); then
  echo "Workspace hooks (shared by all machines)"
  if [[ -f "$WORKSPACE_SETTINGS" ]]; then
    apply "$WORKSPACE_SETTINGS" 'del(.hooks)'
  else
    echo "  not found: $WORKSPACE_SETTINGS"
  fi
fi

if (( ! KEEP_PLUGINS )); then
  echo "4. Plugins"
  if ! command -v claude >/dev/null; then
    echo "  claude not on PATH; skipped"
  else
    for p in $PLUGINS; do
      if (( DRY )); then
        echo "  would run: claude plugin disable $p"
      elif claude plugin disable "$p" >/dev/null 2>&1; then
        echo "  disabled: $p"
      else
        echo "  not disabled (already off, not installed, or managed on claude.ai): $p"
      fi
    done
  fi
fi

echo "Done. Restart any running Claude Code sessions to pick up the changes."
