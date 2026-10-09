#!/usr/bin/env bats
# Tests for scripts/pr-unresolved-threads.sh
#
# A stub gh serves a fixture GraphQL response and applies the script's real --jq filter
# with jq, so the filter itself is exercised. The stub also logs its arguments.

bats_require_minimum_version 1.5.0

SCRIPT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/pr-unresolved-threads.sh"

setup() {
  STUB_DIR="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$STUB_DIR"
  export GH_LOG="$BATS_TEST_TMPDIR/gh.log"
  export FIXTURE="$BATS_TEST_TMPDIR/threads.json"
  cat > "$STUB_DIR/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GH_LOG"
[[ -n "${GH_FAIL:-}" ]] && { echo "gh: boom" >&2; exit 1; }
filter=""
while [[ $# -gt 0 ]]; do
  [[ "$1" == "--jq" ]] && { filter=$2; shift; }
  shift
done
jq -r "$filter" "$FIXTURE"
STUB
  chmod +x "$STUB_DIR/gh"
  PATH="$STUB_DIR:$PATH"
}

# thread <id> <resolved> <author> <path> <line> <body>: one reviewThreads node as JSON.
thread() {
  jq -n --arg id "$1" --argjson res "$2" --arg a "$3" --arg p "$4" --argjson l "$5" --arg b "$6" \
    '{id:$id,isResolved:$res,path:$p,line:$l,originalLine:$l,
      comments:{nodes:[{author:{login:$a},body:$b}]}}'
}

# fixture <thread-json>...: write a GraphQL response holding the given nodes.
fixture() {
  printf '%s\n' "$@" | jq -s '{data:{repository:{pullRequest:{reviewThreads:{
    pageInfo:{hasNextPage:false,endCursor:null},nodes:.}}}}}' > "$FIXTURE"
}

@test "exits 0 and prints nothing on stdout when every thread is resolved" {
  fixture "$(thread T1 true copilot-pull-request-reviewer a.java 3 'ok')"

  run --separate-stderr bash "$SCRIPT" xpq-api 7

  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [[ "$stderr" == *"0 unresolved"* ]]
}

@test "exits 0 when the PR has no threads at all" {
  fixture

  run bash "$SCRIPT" xpq-api 7

  [ "$status" -eq 0 ]
}

@test "exits 1 and lists each unresolved thread" {
  fixture \
    "$(thread T1 true  copilot-pull-request-reviewer a.java 3 'resolved one')" \
    "$(thread T2 false copilot-pull-request-reviewer src/B.java 42 $'null check missing\nsecond line')" \
    "$(thread T3 false someone-human README.md 9 'typo')"

  run --separate-stderr bash "$SCRIPT" xpq-api 7

  [ "$status" -eq 1 ]
  [[ "$output" == *$'T2\tcopilot-pull-request-reviewer\tsrc/B.java:42\tnull check missing'* ]]
  [[ "$output" == *$'T3\tsomeone-human\tREADME.md:9\ttypo'* ]]
  [[ "$output" != *"T1"* ]]
  [[ "$output" != *"second line"* ]]
  [[ "$stderr" == *"2 unresolved"* ]]
}

@test "exits 2 when the API call fails" {
  fixture
  export GH_FAIL=1

  run bash "$SCRIPT" xpq-api 7

  [ "$status" -eq 2 ]
}

@test "exits 2 on missing or non-numeric arguments" {
  run bash "$SCRIPT" xpq-api
  [ "$status" -eq 2 ]

  run bash "$SCRIPT" xpq-api seven
  [ "$status" -eq 2 ]
}

@test "a bare repo name is qualified with the XP-Quest org" {
  fixture

  bash "$SCRIPT" xpq-api 7

  grep -q 'owner=XP-Quest' "$GH_LOG"
  grep -q 'repo=xpq-api' "$GH_LOG"
}

@test "the org repo .github and an explicit owner/name are accepted" {
  fixture

  bash "$SCRIPT" .github 7
  grep -q 'repo=.github' "$GH_LOG"

  bash "$SCRIPT" Other-Org/some-repo 7
  grep -q 'owner=Other-Org' "$GH_LOG"
  grep -q 'repo=some-repo' "$GH_LOG"
}
