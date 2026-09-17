#!/usr/bin/env bats
bats_require_minimum_version 1.5.0
# Tests for scripts/daily_git_summary.sh
#
# Validates the three-layer commit-tracking scheme described in
# SR_ED_CONVENTIONS.md "How the parser stays accurate":
#
#   Layer 1 — commits whose subjects carry a '#NN: ' prefix are directly
#              attributed to the matching issue.
#   Layer 2 — commits without a prefix are attributed via the branch name
#              (<issue>-<slug>) that contains them.
#   Layer 3 — commits that survive both layers land in an (untracked) section
#              for human review.
#
# Environment variables used by the script and set here for isolation:
#   SEARCH_ROOT          — directory tree searched for git repos
#   OUTPUT_DIR           — where the markdown summary file is written
#   XPQUEST_SUMMARY_DIR  — Time Tracker daily-summary-<DATE>.json lookup override
#   XPQUEST_HOST_ID      — overrides the `hostname`-derived label used to attribute this
#                          run's Time Tracking contribution for cross-host merge (#41)
#   MEETINGS_DIR         — meeting-notes directory
#   HOME                 — redirected so the $HOME/.xpquest summary fallback is hermetic

SCRIPT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/daily_git_summary.sh"
HELPERS_DIR="$(dirname "$BATS_TEST_FILENAME")/helpers"

# Fixed test date so commits don't have to land "today".
TEST_DATE="2026-01-15"
GIT_DATE="${TEST_DATE}T12:00:00"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

setup() {
  TEST_DIR="$(mktemp -d)"

  # Prepend the mock gh binary so the script never contacts GitHub.
  export PATH="$HELPERS_DIR:$PATH"

  # Isolate script outputs.
  export SEARCH_ROOT="$TEST_DIR/repos"
  export OUTPUT_DIR="$TEST_DIR/output"

  # Isolate the Time Tracker summary lookup and meetings scan from the developer's
  # real environment. Redirecting HOME makes the $HOME/.xpquest fallback hermetic;
  # the /mnt/c glob (third tier) is environment-specific and not exercised here.
  export HOME="$TEST_DIR/home"
  export XPQUEST_SUMMARY_DIR="$TEST_DIR/widget"
  export MEETINGS_DIR="$TEST_DIR/meetings"

  mkdir -p "$SEARCH_ROOT" "$OUTPUT_DIR" "$HOME" "$XPQUEST_SUMMARY_DIR"
}

teardown() {
  rm -rf "$TEST_DIR"
}

# Create a minimal git repo in SEARCH_ROOT, return its path in $REPO_DIR.
make_repo() {
  local name="${1:-repo}"
  REPO_DIR="$SEARCH_ROOT/$name"
  mkdir -p "$REPO_DIR"
  git init -q "$REPO_DIR"
  git -C "$REPO_DIR" config user.email "test@example.com"
  git -C "$REPO_DIR" config user.name "Test User"
  # Add a fake origin so repo_identifier() can derive an org/repo string.
  git -C "$REPO_DIR" remote add origin "https://github.com/XP-Quest/$name"
}

# Make an empty commit in REPO_DIR with a controlled author/committer date.
make_commit() {
  local msg="$1"
  GIT_AUTHOR_DATE="$GIT_DATE" \
  GIT_COMMITTER_DATE="$GIT_DATE" \
    git -C "$REPO_DIR" commit --allow-empty -q -m "$msg"
}

# Return the short SHA of the most recent commit in REPO_DIR.
last_sha() {
  git -C "$REPO_DIR" log -1 --format='%h'
}

# Write a Time Tracker daily-summary JSON for TEST_DATE into the widget override
# dir ($XPQUEST_SUMMARY_DIR, first resolution tier). Arg: the JSON body.
write_widget_summary() {
  mkdir -p "$XPQUEST_SUMMARY_DIR"
  printf '%s\n' "$1" > "$XPQUEST_SUMMARY_DIR/daily-summary-${TEST_DATE}.json"
}

# Write a Time Tracker daily-summary JSON for TEST_DATE into $HOME/.xpquest
# (second resolution tier). Arg: the JSON body.
write_home_summary() {
  mkdir -p "$HOME/.xpquest"
  printf '%s\n' "$1" > "$HOME/.xpquest/daily-summary-${TEST_DATE}.json"
}

# Path to the github summary file produced for TEST_DATE.
summary_out() {
  printf '%s' "$OUTPUT_DIR/github_summary-${TEST_DATE}.md"
}

# Decoded JSON body of the hidden tracker-state comment in the given file
# (default: this date's github summary). Empty if no comment is present.
tracker_state_json() {
  local file="${1:-$(summary_out)}"
  sed -n '/<!-- tracker-state$/,/^tracker-state -->/p' "$file" | sed '1d;$d' | base64 -d 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Basic behaviour
# ---------------------------------------------------------------------------

@test "no git repos under SEARCH_ROOT: exits 0 without creating output file" {
  run bash "$SCRIPT" "$TEST_DATE"

  [ "$status" -eq 0 ]
  [ -z "$(ls -A "$OUTPUT_DIR")" ]
}

@test "repo exists but has no commits on TARGET_DATE: exits 0 without file" {
  make_repo "empty-repo"
  # Make a commit on a different date so the repo is not empty.
  GIT_AUTHOR_DATE="2025-06-01T10:00:00" \
  GIT_COMMITTER_DATE="2025-06-01T10:00:00" \
    git -C "$REPO_DIR" commit --allow-empty -q -m "#1: old commit"

  run bash "$SCRIPT" "$TEST_DATE"

  [ "$status" -eq 0 ]
  [ -z "$(ls -A "$OUTPUT_DIR")" ]
}

@test "output file is named github_summary-YYYY-MM-DD.md" {
  make_repo "testrepo"
  make_commit "#1: initial commit"

  run bash "$SCRIPT" "$TEST_DATE"

  [ "$status" -eq 0 ]
  [ -f "$OUTPUT_DIR/github_summary-${TEST_DATE}.md" ]
}

@test "output file header contains the target date" {
  make_repo "testrepo"
  make_commit "#1: initial commit"

  bash "$SCRIPT" "$TEST_DATE"

  grep -q "$TEST_DATE" "$OUTPUT_DIR/github_summary-${TEST_DATE}.md"
}

# ---------------------------------------------------------------------------
# Layer 1: direct '#NN: ' subject attribution
# ---------------------------------------------------------------------------

@test "Layer 1: commit with '#42: ...' subject is attributed to issue 42" {
  make_repo "testrepo"
  make_commit "#42: add FixedSizeChunker baseline at 512/64"

  bash "$SCRIPT" "$TEST_DATE"

  grep -q "#42" "$OUTPUT_DIR/github_summary-${TEST_DATE}.md"
}

@test "Layer 1: rendered subject strips the '#NN: ' prefix from the commit SHA line" {
  make_repo "testrepo"
  make_commit "#42: add FixedSizeChunker baseline at 512/64"

  bash "$SCRIPT" "$TEST_DATE"

  grep -q "add FixedSizeChunker baseline at 512/64" \
    "$OUTPUT_DIR/github_summary-${TEST_DATE}.md"
}

@test "Layer 1: two commits on the same issue both appear in the output" {
  make_repo "testrepo"
  make_commit "#42: add FixedSizeChunker baseline at 512/64"
  make_commit "#42: add token-count metrics to chunker output"

  bash "$SCRIPT" "$TEST_DATE"

  local out="$OUTPUT_DIR/github_summary-${TEST_DATE}.md"
  grep -c "#42" "$out" | grep -q "2"
}

@test "Layer 1: commits for different issues both appear in their own sections" {
  make_repo "testrepo"
  make_commit "#42: add FixedSizeChunker"
  make_commit "#58: add OIDC ingress filter"

  bash "$SCRIPT" "$TEST_DATE"

  local out="$OUTPUT_DIR/github_summary-${TEST_DATE}.md"
  grep -q "#42" "$out"
  grep -q "#58" "$out"
}

@test "Layer 1: repo section header uses the repository directory name" {
  make_repo "xpq-api"
  make_commit "#42: some work"

  bash "$SCRIPT" "$TEST_DATE"

  grep -q "## xpq-api" "$OUTPUT_DIR/github_summary-${TEST_DATE}.md"
}

# ---------------------------------------------------------------------------
# Layer 2: branch-name fallback attribution
# ---------------------------------------------------------------------------

@test "Layer 2: commit without '#NN: ' prefix is attributed via '<N>-<slug>' branch" {
  make_repo "testrepo"
  # Create a branch named 99-relevance-gate and commit on it.
  git -C "$REPO_DIR" checkout -q -b 99-relevance-gate
  make_commit "tune relevance threshold"

  bash "$SCRIPT" "$TEST_DATE"

  grep -q "#99" "$OUTPUT_DIR/github_summary-${TEST_DATE}.md"
}

@test "Layer 2: branch-recovered commit does NOT appear in (untracked)" {
  make_repo "testrepo"
  git -C "$REPO_DIR" checkout -q -b 99-relevance-gate
  make_commit "tune relevance threshold"

  bash "$SCRIPT" "$TEST_DATE"

  run ! grep -q "(untracked)" "$OUTPUT_DIR/github_summary-${TEST_DATE}.md"
}

@test "Layer 2: origin/<N>-<slug> remote branch is preferred over local when both present" {
  make_repo "testrepo"
  # Simulate origin/10-feature by creating a remote-tracking ref directly.
  git -C "$REPO_DIR" checkout -q -b 10-feature
  make_commit "work on feature"
  local sha
  sha=$(last_sha)
  # Also create a local branch with a higher issue number that should lose.
  git -C "$REPO_DIR" branch 20-other-feature
  # Manually create a remote-tracking ref for the lower-numbered branch.
  git -C "$REPO_DIR" update-ref refs/remotes/origin/10-feature "$sha"

  bash "$SCRIPT" "$TEST_DATE"

  # Issue 10 (origin branch) should win over issue 20 (local-only).
  grep -q "#10" "$OUTPUT_DIR/github_summary-${TEST_DATE}.md"
}

# ---------------------------------------------------------------------------
# Layer 3: (untracked) section
# ---------------------------------------------------------------------------

@test "Layer 3: commit with no '#NN: ' and no matching branch lands in (untracked)" {
  make_repo "testrepo"
  # Commit on 'main' (no issue number in branch name) without a '#NN: ' prefix.
  make_commit "orphaned work without an issue reference"

  bash "$SCRIPT" "$TEST_DATE"

  grep -q "(untracked)" "$OUTPUT_DIR/github_summary-${TEST_DATE}.md"
}

@test "Layer 3: (untracked) entry includes the repo name and short SHA" {
  make_repo "xpq-api"
  make_commit "orphaned commit"
  local sha
  sha=$(last_sha)

  bash "$SCRIPT" "$TEST_DATE"

  grep -q "xpq-api" "$OUTPUT_DIR/github_summary-${TEST_DATE}.md"
  grep -q "$sha"   "$OUTPUT_DIR/github_summary-${TEST_DATE}.md"
}

@test "Layer 3: (untracked) section explains how to attribute the commit" {
  make_repo "testrepo"
  make_commit "no issue ref"

  bash "$SCRIPT" "$TEST_DATE"

  grep -q "amending the commit subject or noting the SHA" \
    "$OUTPUT_DIR/github_summary-${TEST_DATE}.md"
}

# ---------------------------------------------------------------------------
# Argument validation
# ---------------------------------------------------------------------------

@test "invalid date argument exits with status 1" {
  run bash "$SCRIPT" "not-a-date"

  [ "$status" -eq 1 ]
  [[ "$output" == *"invalid date"* ]]
}

@test "invalid date error message echoes the bad input" {
  run bash "$SCRIPT" "not-a-date"

  [[ "$output" == *"not-a-date"* ]]
}

# ---------------------------------------------------------------------------
# Multiple repos
# ---------------------------------------------------------------------------

@test "commits from multiple repos each get their own section" {
  make_repo "xpq-api"
  make_commit "#42: api work"

  make_repo "xpq-web"
  make_commit "#58: web work"

  bash "$SCRIPT" "$TEST_DATE"

  local out="$OUTPUT_DIR/github_summary-${TEST_DATE}.md"
  grep -q "## xpq-api" "$out"
  grep -q "## xpq-web" "$out"
}

# ---------------------------------------------------------------------------
# Time Tracker rendering — the '## Time Tracking' block folded in from the
# widget's daily-summary-<DATE>.json. These tests deliberately use no commits:
# a summary file alone is sufficient to produce the output file, which keeps
# them hermetic and independent of issue/gh resolution.
# ---------------------------------------------------------------------------

@test "Time block: a summary JSON alone (no commits) produces the output file" {
  write_widget_summary '{"projects":[{"workstream":"engineering","code":"xpq-eng","name":"Solo time entry","seconds":3600}]}'

  run bash "$SCRIPT" "$TEST_DATE"

  [ "$status" -eq 0 ]
  [ -f "$(summary_out)" ]
  grep -q "## Time Tracking" "$(summary_out)"
}

@test "Time block: no summary file anywhere means no '## Time Tracking' section" {
  make_repo "testrepo"
  make_commit "#42: some work"

  bash "$SCRIPT" "$TEST_DATE"

  run ! grep -q "## Time Tracking" "$(summary_out)"
}

@test "Time block: projects group into Engineering / R&D, SR&ED, and Client headers" {
  write_widget_summary '{"projects":[
    {"workstream":"engineering","code":"xpq-eng","name":"Eng work","seconds":3600},
    {"workstream":"sred","code":"xpq-sred","name":"Research","seconds":3600},
    {"workstream":"client","code":"acme-x","name":"Client work","seconds":3600,"client":"Acme Corp"}
  ]}'

  bash "$SCRIPT" "$TEST_DATE"

  grep -qF '### Engineering / R&D' "$(summary_out)"
  grep -qF '### SR&ED' "$(summary_out)"
  grep -qF '### Client' "$(summary_out)"
}

@test "Time block: workstream sections are ordered engineering, SR&ED, client" {
  write_widget_summary '{"projects":[
    {"workstream":"client","code":"acme-x","name":"Client work","seconds":3600,"client":"Acme Corp"},
    {"workstream":"sred","code":"xpq-sred","name":"Research","seconds":3600},
    {"workstream":"engineering","code":"xpq-eng","name":"Eng work","seconds":3600}
  ]}'

  bash "$SCRIPT" "$TEST_DATE"

  run grep -nE '^### (Engineering / R&D|SR&ED|Client)$' "$(summary_out)"
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" == *"Engineering / R&D"* ]]
  [[ "${lines[1]}" == *"SR&ED"* ]]
  [[ "${lines[2]}" == *"Client"* ]]
}

@test "Time block: an unrecognized workstream keeps its raw name and sorts last" {
  write_widget_summary '{"projects":[
    {"workstream":"engineering","code":"xpq-eng","name":"Eng work","seconds":3600},
    {"workstream":"research","code":"xpq-misc","name":"Odd work","seconds":3600}
  ]}'

  bash "$SCRIPT" "$TEST_DATE"

  run grep -nE '^### ' "$(summary_out)"
  [[ "${lines[0]}" == *"Engineering / R&D"* ]]
  [[ "${lines[1]}" == *"### research"* ]]
}

@test "Time block: project bullet shows code, name, and H:MM duration" {
  write_widget_summary '{"projects":[{"workstream":"engineering","code":"xpq-eng","name":"Chunker spike","seconds":3900}]}'

  bash "$SCRIPT" "$TEST_DATE"

  grep -qF -- '- **[xpq-eng] Chunker spike** — 1:05' "$(summary_out)"
}

@test "Time block: minutes are zero-padded and sub-hour durations show 0 hours" {
  write_widget_summary '{"projects":[
    {"workstream":"engineering","code":"xpq-eng","name":"OneMinPast","seconds":3660},
    {"workstream":"engineering","code":"xpq-eng","name":"QuarterHour","seconds":1500}
  ]}'

  bash "$SCRIPT" "$TEST_DATE"

  grep -qF -- '- **[xpq-eng] OneMinPast** — 1:01' "$(summary_out)"
  grep -qF -- '- **[xpq-eng] QuarterHour** — 0:25' "$(summary_out)"
}

@test "Time block: description is appended after the duration when present" {
  write_widget_summary '{"projects":[{"workstream":"engineering","code":"xpq-eng","name":"Gate","seconds":3600,"description":"tune relevance gate"}]}'

  bash "$SCRIPT" "$TEST_DATE"

  grep -qF -- '— tune relevance gate' "$(summary_out)"
}

@test "Time block: bullet has no trailing description when none is given" {
  write_widget_summary '{"projects":[{"workstream":"engineering","code":"xpq-eng","name":"Plumbing","seconds":3600}]}'

  bash "$SCRIPT" "$TEST_DATE"

  # Whole-line match proves nothing is appended after the duration.
  grep -qxF -- '- **[xpq-eng] Plumbing** — 1:00' "$(summary_out)"
}

@test "Time block: client name is appended in parentheses when present" {
  write_widget_summary '{"projects":[{"workstream":"client","code":"acme-x","name":"Client work","seconds":3600,"client":"Acme Corp"}]}'

  bash "$SCRIPT" "$TEST_DATE"

  grep -qF -- '(Acme Corp)' "$(summary_out)"
}

@test "Time block: Total tracked sums seconds across all projects" {
  write_widget_summary '{"projects":[
    {"workstream":"engineering","code":"xpq-eng","name":"A","seconds":3600},
    {"workstream":"sred","code":"xpq-sred","name":"B","seconds":1800}
  ]}'

  bash "$SCRIPT" "$TEST_DATE"

  grep -qF -- '**Total tracked:** 1:30' "$(summary_out)"
}

# ---------------------------------------------------------------------------
# Time Tracker file resolution — override → $HOME/.xpquest → (/mnt/c, untested)
# ---------------------------------------------------------------------------

@test "Resolution: XPQUEST_SUMMARY_DIR override is used when the dated file exists there" {
  write_widget_summary '{"projects":[{"workstream":"engineering","code":"WIDGETONLY","name":"x","seconds":3600}]}'

  bash "$SCRIPT" "$TEST_DATE"

  grep -q "WIDGETONLY" "$(summary_out)"
}

@test "Resolution: falls back to \$HOME/.xpquest when the override is unset" {
  unset XPQUEST_SUMMARY_DIR
  write_home_summary '{"projects":[{"workstream":"engineering","code":"HOMEONLY","name":"x","seconds":3600}]}'

  bash "$SCRIPT" "$TEST_DATE"

  grep -q "HOMEONLY" "$(summary_out)"
}

@test "Resolution: override takes precedence over \$HOME/.xpquest when both exist" {
  write_widget_summary '{"projects":[{"workstream":"engineering","code":"FROMWIDGET","name":"x","seconds":3600}]}'
  write_home_summary   '{"projects":[{"workstream":"engineering","code":"FROMHOME","name":"x","seconds":3600}]}'

  bash "$SCRIPT" "$TEST_DATE"

  grep -q "FROMWIDGET" "$(summary_out)"
  run ! grep -q "FROMHOME" "$(summary_out)"
}

@test "Resolution: override dir set but file missing there falls back to \$HOME/.xpquest" {
  # XPQUEST_SUMMARY_DIR is exported by setup() but holds no dated file.
  write_home_summary '{"projects":[{"workstream":"engineering","code":"HOMEFALLBACK","name":"x","seconds":3600}]}'

  bash "$SCRIPT" "$TEST_DATE"

  grep -q "HOMEFALLBACK" "$(summary_out)"
}

# ---------------------------------------------------------------------------
# Multi-machine Time Tracking merge — OUTPUT_FILE lives in the shared OneDrive
# Daily-Logs folder, so a second host's run must accumulate onto whatever a
# prior host already wrote there rather than overwrite it. See XP-Quest/.github#41.
# ---------------------------------------------------------------------------

@test "Merge: a second host's run sums seconds for the same code+name into one line" {
  write_widget_summary '{"projects":[{"workstream":"engineering","code":"xpq-eng","name":"XP Quest engineering","seconds":1800}]}'
  XPQUEST_HOST_ID=flash bash "$SCRIPT" "$TEST_DATE"
  grep -qxF -- '- **[xpq-eng] XP Quest engineering** — 0:30' "$(summary_out)"

  write_widget_summary '{"projects":[{"workstream":"engineering","code":"xpq-eng","name":"XP Quest engineering","seconds":3600}]}'
  XPQUEST_HOST_ID=antman bash "$SCRIPT" "$TEST_DATE"

  # One merged line at 1800+3600s = 1:30, not two separate lines.
  grep -qxF -- '- **[xpq-eng] XP Quest engineering** — 1:30' "$(summary_out)"
  run grep -cF -- '[xpq-eng] XP Quest engineering' "$(summary_out)"
  [ "$output" -eq 1 ]
  grep -qF -- '**Total tracked:** 1:30' "$(summary_out)"
}

@test "Merge: re-running the same host with unchanged hours does not double-count" {
  write_widget_summary '{"projects":[{"workstream":"engineering","code":"xpq-eng","name":"XP Quest engineering","seconds":1800}]}'
  XPQUEST_HOST_ID=flash bash "$SCRIPT" "$TEST_DATE"
  XPQUEST_HOST_ID=flash bash "$SCRIPT" "$TEST_DATE"
  XPQUEST_HOST_ID=flash bash "$SCRIPT" "$TEST_DATE"

  grep -qxF -- '- **[xpq-eng] XP Quest engineering** — 0:30' "$(summary_out)"
  grep -qF -- '**Total tracked:** 0:30' "$(summary_out)"
}

@test "Merge: same host's changed hours replace (not add to) its own prior contribution" {
  write_widget_summary '{"projects":[{"workstream":"engineering","code":"xpq-eng","name":"XP Quest engineering","seconds":1800}]}'
  XPQUEST_HOST_ID=flash bash "$SCRIPT" "$TEST_DATE"

  # Same host, same code+name, updated (grown) seconds — replaces, not adds.
  write_widget_summary '{"projects":[{"workstream":"engineering","code":"xpq-eng","name":"XP Quest engineering","seconds":3600}]}'
  XPQUEST_HOST_ID=flash bash "$SCRIPT" "$TEST_DATE"

  grep -qxF -- '- **[xpq-eng] XP Quest engineering** — 1:00' "$(summary_out)"
}

@test "Merge: a code+name unique to one host is preserved when the other host contributes different work" {
  write_widget_summary '{"projects":[{"workstream":"sred","code":"xpq-sred","name":"Research","seconds":900}]}'
  XPQUEST_HOST_ID=antman bash "$SCRIPT" "$TEST_DATE"

  write_widget_summary '{"projects":[{"workstream":"engineering","code":"xpq-eng","name":"XP Quest engineering","seconds":1800}]}'
  XPQUEST_HOST_ID=flash bash "$SCRIPT" "$TEST_DATE"

  grep -qxF -- '- **[xpq-sred] Research** — 0:15' "$(summary_out)"
  grep -qxF -- '- **[xpq-eng] XP Quest engineering** — 0:30' "$(summary_out)"
  grep -qF -- '**Total tracked:** 0:45' "$(summary_out)"
}

@test "Merge: the same code with different names from a single run stays two distinct lines" {
  # Not a cross-host scenario — the join key is code+name together, so two
  # genuinely different projects that happen to reuse a code are never conflated.
  write_widget_summary '{"projects":[
    {"workstream":"engineering","code":"xpq-eng","name":"OneMinPast","seconds":3660},
    {"workstream":"engineering","code":"xpq-eng","name":"QuarterHour","seconds":1500}
  ]}'

  bash "$SCRIPT" "$TEST_DATE"

  grep -qxF -- '- **[xpq-eng] OneMinPast** — 1:01' "$(summary_out)"
  grep -qxF -- '- **[xpq-eng] QuarterHour** — 0:25' "$(summary_out)"
}

@test "Merge: the hidden tracker-state comment carries host attribution but no host name appears in a visible bullet" {
  write_widget_summary '{"projects":[{"workstream":"engineering","code":"xpq-eng","name":"XP Quest engineering","seconds":1800}]}'
  XPQUEST_HOST_ID=flash bash "$SCRIPT" "$TEST_DATE"

  grep -q "tracker-state" "$(summary_out)"
  run tracker_state_json
  [[ "$output" == *'"flash"'* ]]
  # The comment itself is base64, so "flash" can't leak into the rendered file
  # unencoded either way — but assert the point explicitly: no visible bullet
  # names the device. Merged content stays organized by section/project, not
  # partitioned by machine.
  run grep -F -- '- **[xpq-eng]' "$(summary_out)"
  [[ "$output" != *"flash"* ]]
}

@test "Merge: the tracker-state comment is base64, not raw JSON (never breakable by '-->' in tracked data)" {
  write_widget_summary '{"projects":[{"workstream":"engineering","code":"xpq-eng","name":"Weird --> name","seconds":60}]}'

  bash "$SCRIPT" "$TEST_DATE"

  # The visible bullet legitimately renders the project name as-is (harmless,
  # not inside a comment) — the thing that must never happen is the hidden
  # state's own closing marker being reachable early. Assert only one line in
  # the whole file matches the closing-marker anchor pattern used to extract it.
  run grep -cE -- '^tracker-state -->$' "$(summary_out)"
  [ "$output" -eq 1 ]

  # The state still round-trips correctly through base64, including the '-->'
  # inside the tracked name — proves encoding, not escaping, is doing the work.
  run tracker_state_json
  [[ "$output" == *"Weird --> name"* ]]

  # A second run must still find and decode the same state cleanly (extraction
  # isn't confused by the '-->' that legitimately appears earlier in the file).
  write_widget_summary '{"projects":[{"workstream":"engineering","code":"xpq-eng","name":"Weird --> name","seconds":120}]}'
  bash "$SCRIPT" "$TEST_DATE"
  grep -qxF -- '- **[xpq-eng] Weird --> name** — 0:02' "$(summary_out)"
}

@test "Merge: a pre-existing visible Time Tracking block with no hidden state is migrated, not dropped" {
  # Simulates a github_summary-DATE.md written before the tracker-state comment
  # existed: a real '## Time Tracking' block, no hidden comment. A later run
  # from a host with no local Tracker JSON for this date, but that DOES have a
  # commit (so the file gets rewritten for another reason), must not silently
  # lose these pre-existing hours.
  mkdir -p "$OUTPUT_DIR"
  cat > "$(summary_out)" <<'EOF'
# XP Quest - GitHub Commit Summary — 2026-01-15

## Time Tracking

### Engineering / R&D

- **[xpq-eng] XP Quest engineering** — 0:03 (XP Quest)

### Client

- **[acme-corp-1] Acme Corp Sample Project** — 6:37 (Acme Corp)

**Total tracked:** 6:40
EOF

  make_repo "testrepo"
  make_commit "#42: unrelated commit that forces a rewrite"
  # No widget summary for this run — this host has no local Tracker JSON for the date.

  bash "$SCRIPT" "$TEST_DATE"

  grep -qxF -- '- **[xpq-eng] XP Quest engineering** — 0:03 (XP Quest)' "$(summary_out)"
  grep -qxF -- '- **[acme-corp-1] Acme Corp Sample Project** — 6:37 (Acme Corp)' "$(summary_out)"
  grep -qF -- '**Total tracked:** 6:40' "$(summary_out)"
  grep -q "tracker-state" "$(summary_out)"
}

@test "Merge: a migrated legacy block still sums correctly once a real host contributes to the same code+name" {
  mkdir -p "$OUTPUT_DIR"
  cat > "$(summary_out)" <<'EOF'
# XP Quest - GitHub Commit Summary — 2026-01-15

## Time Tracking

### Engineering / R&D

- **[xpq-eng] XP Quest engineering** — 0:30

**Total tracked:** 0:30
EOF

  write_widget_summary '{"projects":[{"workstream":"engineering","code":"xpq-eng","name":"XP Quest engineering","seconds":3600}]}'
  XPQUEST_HOST_ID=antman bash "$SCRIPT" "$TEST_DATE"

  # 1800s (legacy) + 3600s (antman) = 5400s = 1:30
  grep -qxF -- '- **[xpq-eng] XP Quest engineering** — 1:30' "$(summary_out)"
  grep -qF -- '**Total tracked:** 1:30' "$(summary_out)"
}

@test "Merge: default host id falls back to the real hostname, lowercased" {
  write_widget_summary '{"projects":[{"workstream":"engineering","code":"xpq-eng","name":"x","seconds":60}]}'

  bash "$SCRIPT" "$TEST_DATE"

  local host_lower
  host_lower=$(hostname | tr '[:upper:]' '[:lower:]')
  run tracker_state_json
  [[ "$output" == *"\"${host_lower}\""* ]]
}

# ---------------------------------------------------------------------------
# daily_log-DATE.md starter draft — must never regress an already-enriched log.
# DAILY_LOG_FILE lives in the shared OneDrive Daily-Logs folder; a second host
# calling this script for an already-enriched date (skill Step 9 output, no
# longer carrying the starter sentinel) must leave it untouched.
# ---------------------------------------------------------------------------

daily_log_out() {
  printf '%s' "$OUTPUT_DIR/daily_log-${TEST_DATE}.md"
}

@test "Starter log: written fresh when no daily_log file exists yet" {
  make_repo "testrepo"
  make_commit "#42: some work"

  bash "$SCRIPT" "$TEST_DATE"

  [ -f "$(daily_log_out)" ]
  grep -q "Session transcripts not included" "$(daily_log_out)"
}

@test "Starter log: regenerated while still in draft form (sentinel present)" {
  make_repo "testrepo"
  make_commit "#42: first commit"
  bash "$SCRIPT" "$TEST_DATE"

  make_commit "#42: second commit"
  bash "$SCRIPT" "$TEST_DATE"

  grep -q "second commit" "$(daily_log_out)"
  grep -q "Session transcripts not included" "$(daily_log_out)"
}

@test "Starter log: an already-enriched file (sentinel absent) is left untouched" {
  mkdir -p "$OUTPUT_DIR"
  cat > "$(daily_log_out)" <<'EOF'
# XP Quest — Daily Log — 2026-01-15

**Summary:** enriched by the skill, including session content.

## Engineering / R&D

- **testrepo** [#42: some work](https://github.com/XP-Quest/testrepo/issues/42)
  - `abc1234`: first commit
  - session bullet from the skill
EOF
  local before
  before=$(cat "$(daily_log_out)")

  make_repo "testrepo"
  make_commit "#42: a brand new commit that would appear in a regenerated draft"
  bash "$SCRIPT" "$TEST_DATE"

  [ "$(cat "$(daily_log_out)")" = "$before" ]
  run ! grep -q "brand new commit" "$(daily_log_out)"
}
