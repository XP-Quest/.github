#!/usr/bin/env bats
# Tests for scripts/session_summary.py
#
# Validates argument handling, the human-message filters, and — most importantly —
# LOCAL calendar-date bucketing. The bucketing case is a regression test for the
# bug fixed in bd1798a: an evening message (after ~20:00 EDT) is already past
# midnight UTC, so matching on the raw UTC timestamp prefix shifted a whole
# evening of session bullets onto the following day, away from the commits they
# belonged with.
#
# Transcripts are synthesized in a temp dir and injected via --sessions-dir, so
# the tests never touch Robin's real ~/.claude transcripts.

SCRIPT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)/session_summary.py"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

setup() {
  TEST_DIR="$(mktemp -d)"
  SESSIONS_DIR="$TEST_DIR/sessions"
  mkdir -p "$SESSIONS_DIR"

  # Pin the zone: bucketing is defined against Robin's local time, and the
  # script resolves it from TZ at runtime (EST/EDT handled automatically).
  export TZ="America/Toronto"
}

teardown() {
  rm -rf "$TEST_DIR"
}

# event <file> <timestamp> <type> <text>
event() {
  local file="$1" timestamp="$2" type="$3" text="$4"
  python3 - "$file" "$timestamp" "$type" "$text" <<'PY'
import json, sys
path, timestamp, type_, text = sys.argv[1:5]
with open(path, "a", encoding="utf-8") as f:
    f.write(json.dumps({
        "timestamp": timestamp,
        "type": type_,
        "message": {"content": text},
    }) + "\n")
PY
}

# meta_event <file> <timestamp> <text> — a harness-injected event (isMeta: true),
# e.g. the SKILL.md body a slash command injects as a `type: user` message.
meta_event() {
  local file="$1" timestamp="$2" text="$3"
  python3 - "$file" "$timestamp" "$text" <<'PY'
import json, sys
path, timestamp, text = sys.argv[1:4]
with open(path, "a", encoding="utf-8") as f:
    f.write(json.dumps({
        "timestamp": timestamp,
        "type": "user",
        "isMeta": True,
        "message": {"content": text},
    }) + "\n")
PY
}

run_script() {
  run python3 "$SCRIPT" "$@" --sessions-dir "$SESSIONS_DIR"
}

# ---------------------------------------------------------------------------
# Argument handling
# ---------------------------------------------------------------------------

@test "--help exits with status 0" {
  run python3 "$SCRIPT" --help

  [ "$status" -eq 0 ]
  [[ "$output" == *"YYYY-MM-DD"* ]]
}

@test "missing date argument exits non-zero" {
  run python3 "$SCRIPT"

  [ "$status" -ne 0 ]
}

@test "invalid date exits with status 1" {
  run_script "not-a-date"

  [ "$status" -eq 1 ]
  [[ "$output" == *"invalid"* ]]
}

@test "invalid date error echoes the bad input" {
  run_script "bad-input"

  [[ "$output" == *"bad-input"* ]]
}

@test "empty sessions dir exits 0 with no output" {
  run_script "2026-07-11"

  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "missing sessions dir exits 0 with no output" {
  run python3 "$SCRIPT" "2026-07-11" --sessions-dir "$TEST_DIR/does-not-exist"

  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# Local-date bucketing (regression: bd1798a)
# ---------------------------------------------------------------------------

@test "evening message stays on its LOCAL date, not the next UTC date" {
  # 2026-07-11 21:30 EDT == 2026-07-12 01:30 UTC. It belongs to 07-11.
  event "$SESSIONS_DIR/a.jsonl" "2026-07-12T01:30:00.000Z" "user" \
    "evening work on the chunker baseline experiment"

  run_script "2026-07-11"

  [ "$status" -eq 0 ]
  [[ "$output" == *"evening work on the chunker baseline"* ]]
}

@test "evening message does NOT appear on the following UTC date" {
  event "$SESSIONS_DIR/a.jsonl" "2026-07-12T01:30:00.000Z" "user" \
    "evening work on the chunker baseline experiment"

  run_script "2026-07-12"

  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "early-morning local message is bucketed to its local date" {
  # 2026-07-11 09:00 EDT == 2026-07-11 13:00 UTC. Same day either way.
  event "$SESSIONS_DIR/a.jsonl" "2026-07-11T13:00:00.000Z" "user" \
    "morning session reviewing the relevance gate thresholds"

  run_script "2026-07-11"

  [[ "$output" == *"morning session reviewing"* ]]
}

@test "messages from other dates are excluded" {
  event "$SESSIONS_DIR/a.jsonl" "2026-07-11T13:00:00.000Z" "user" \
    "message belonging to the eleventh of July"
  event "$SESSIONS_DIR/a.jsonl" "2026-07-13T13:00:00.000Z" "user" \
    "message belonging to the thirteenth of July"

  run_script "2026-07-11"

  [[ "$output" == *"eleventh"* ]]
  [[ "$output" != *"thirteenth"* ]]
}

# ---------------------------------------------------------------------------
# Message filtering
# ---------------------------------------------------------------------------

@test "non-user events are excluded" {
  event "$SESSIONS_DIR/a.jsonl" "2026-07-11T13:00:00.000Z" "assistant" \
    "assistant reply that must never reach the daily log"

  run_script "2026-07-11"

  [ -z "$output" ]
}

@test "system-reminder envelopes (leading <) are excluded" {
  event "$SESSIONS_DIR/a.jsonl" "2026-07-11T13:00:00.000Z" "user" \
    "<system-reminder>injected context that is not human input</system-reminder>"

  run_script "2026-07-11"

  [ -z "$output" ]
}

@test "serialized block arrays (leading [{) are excluded" {
  event "$SESSIONS_DIR/a.jsonl" "2026-07-11T13:00:00.000Z" "user" \
    '[{"tool_use_id": "abc", "type": "tool_result"}]'

  run_script "2026-07-11"

  [ -z "$output" ]
}

@test "short acknowledgements (<= 20 chars) are excluded" {
  event "$SESSIONS_DIR/a.jsonl" "2026-07-11T13:00:00.000Z" "user" "yes, go ahead"

  run_script "2026-07-11"

  [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# Harness-injected content (issue #39)
#
# Slash-command invocations inject the skill's own SKILL.md body as a `type: user`
# event. It has no `<` or `[{` prefix and is long, so the text filters alone let it
# through — it reached the 2026-07-11 daily log as if Robin had typed it. The
# transcript flags these `isMeta: true`.
# ---------------------------------------------------------------------------

@test "isMeta events are excluded (slash-command skill preamble)" {
  meta_event "$SESSIONS_DIR/a.jsonl" "2026-07-11T13:00:00.000Z" \
    "Base directory for this skill: /home/rcoe/.claude/skills/xpquest-daily-log"

  run_script "2026-07-11"

  [ -z "$output" ]
}

@test "isMeta events are excluded regardless of which skill injected them" {
  meta_event "$SESSIONS_DIR/a.jsonl" "2026-07-11T13:00:00.000Z" \
    "# Schedule Cloud Agents

You are helping the user schedule a recurring cloud agent."

  run_script "2026-07-11"

  [ -z "$output" ]
}

@test "an isMeta preamble does not crowd out real messages in the same session" {
  # Regression: on 2026-07-11 the preamble consumed 2 of the 5 printed slots.
  meta_event "$SESSIONS_DIR/a.jsonl" "2026-07-11T13:00:00.000Z" \
    "Base directory for this skill: /home/rcoe/.claude/skills/xpquest-daily-log"
  event "$SESSIONS_DIR/a.jsonl" "2026-07-11T13:05:00.000Z" "user" \
    "the real instruction Robin actually typed into the session"

  run_script "2026-07-11" --max-messages 1

  [[ "$output" == *"the real instruction Robin actually typed"* ]]
  [[ "$output" != *"Base directory for this skill"* ]]
}

@test "messages without an isMeta flag are retained" {
  # Most of the historical corpus predates the `origin` field, so absence of
  # provenance metadata must never be read as 'injected'.
  event "$SESSIONS_DIR/a.jsonl" "2026-07-11T13:00:00.000Z" "user" \
    "an ordinary message carrying no provenance metadata at all"

  run_script "2026-07-11"

  [[ "$output" == *"ordinary message carrying no provenance"* ]]
}

@test "isMeta: false is treated as human input" {
  python3 - "$SESSIONS_DIR/a.jsonl" <<'PY'
import json, sys
with open(sys.argv[1], "a", encoding="utf-8") as f:
    f.write(json.dumps({
        "timestamp": "2026-07-11T13:00:00.000Z",
        "type": "user",
        "isMeta": False,
        "message": {"content": "explicitly flagged as not injected, so keep it"},
    }) + "\n")
PY

  run_script "2026-07-11"

  [[ "$output" == *"explicitly flagged as not injected"* ]]
}

# ---------------------------------------------------------------------------
# Interruption markers (issue #39)
#
# Written by the harness when a turn is cut short. Long enough to clear the
# length filter, and NOT flagged isMeta — so they need naming explicitly.
# ---------------------------------------------------------------------------

@test "interruption markers are excluded" {
  event "$SESSIONS_DIR/a.jsonl" "2026-07-11T13:00:00.000Z" "user" \
    "[Request interrupted by user]"

  run_script "2026-07-11"

  [ -z "$output" ]
}

@test "the 'for tool use' interruption variant is excluded" {
  event "$SESSIONS_DIR/a.jsonl" "2026-07-11T13:00:00.000Z" "user" \
    "[Request interrupted by user for tool use]"

  run_script "2026-07-11"

  [ -z "$output" ]
}

@test "a message merely quoting an interruption marker is retained" {
  # The filter anchors on the prefix, so quoting the marker mid-sentence is safe.
  event "$SESSIONS_DIR/a.jsonl" "2026-07-11T13:00:00.000Z" "user" \
    "why does the log keep showing [Request interrupted by user] as a message?"

  run_script "2026-07-11"

  [[ "$output" == *"why does the log keep showing"* ]]
}

@test "events with no timestamp are excluded" {
  printf '%s\n' '{"type":"user","message":{"content":"no timestamp on this event at all"}}' \
    > "$SESSIONS_DIR/a.jsonl"

  run_script "2026-07-11"

  [ -z "$output" ]
}

@test "events with non-string timestamp are excluded (and do not crash)" {
  printf '%s\n' '{"timestamp":123,"type":"user","message":{"content":"a message long enough to pass the length filter"}}' \
    > "$SESSIONS_DIR/a.jsonl"

  run_script "2026-07-11"

  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "corrupt JSON lines are tolerated and do not abort the run" {
  printf '%s\n' 'this is not valid json {{{' > "$SESSIONS_DIR/a.jsonl"
  event "$SESSIONS_DIR/a.jsonl" "2026-07-11T13:00:00.000Z" "user" \
    "a perfectly good message following a corrupt line"

  run_script "2026-07-11"

  [ "$status" -eq 0 ]
  [[ "$output" == *"perfectly good message"* ]]
}

# ---------------------------------------------------------------------------
# Structured content blocks
# ---------------------------------------------------------------------------

@test "text blocks in list content are extracted; non-text blocks are ignored" {
  python3 - "$SESSIONS_DIR/a.jsonl" <<'PY'
import json, sys
with open(sys.argv[1], "a", encoding="utf-8") as f:
    f.write(json.dumps({
        "timestamp": "2026-07-11T13:00:00.000Z",
        "type": "user",
        "message": {"content": [
            {"type": "tool_result", "content": "machine chatter to be dropped"},
            {"type": "text", "text": "the human sentence that should survive extraction"},
        ]},
    }) + "\n")
PY

  run_script "2026-07-11"

  [[ "$output" == *"human sentence that should survive"* ]]
  [[ "$output" != *"machine chatter"* ]]
}

# ---------------------------------------------------------------------------
# Output shape
# ---------------------------------------------------------------------------

@test "output is headed by the session file path" {
  event "$SESSIONS_DIR/a.jsonl" "2026-07-11T13:00:00.000Z" "user" \
    "a message long enough to pass the length filter"

  run_script "2026-07-11"

  [[ "$output" == *"--- $SESSIONS_DIR/a.jsonl"* ]]
}

@test "sessions with no messages on the date are omitted entirely" {
  event "$SESSIONS_DIR/quiet.jsonl" "2026-07-13T13:00:00.000Z" "user" \
    "this session was only active on the thirteenth"
  event "$SESSIONS_DIR/busy.jsonl" "2026-07-11T13:00:00.000Z" "user" \
    "this session was active on the eleventh"

  run_script "2026-07-11"

  [[ "$output" == *"busy.jsonl"* ]]
  [[ "$output" != *"quiet.jsonl"* ]]
}

@test "multiple sessions are each reported under their own header" {
  event "$SESSIONS_DIR/a.jsonl" "2026-07-11T13:00:00.000Z" "user" \
    "work carried out in the first session"
  event "$SESSIONS_DIR/b.jsonl" "2026-07-11T14:00:00.000Z" "user" \
    "work carried out in the second session"

  run_script "2026-07-11"

  [ "$(grep -c '^--- ' <<<"$output")" -eq 2 ]
  [[ "$output" == *"first session"* ]]
  [[ "$output" == *"second session"* ]]
}

@test "--max-messages caps the messages printed per session" {
  for n in 1 2 3 4; do
    event "$SESSIONS_DIR/a.jsonl" "2026-07-11T1${n}:00:00.000Z" "user" \
      "message number ${n} in this session transcript"
  done

  run_script "2026-07-11" --max-messages 2

  [[ "$output" == *"message number 1"* ]]
  [[ "$output" == *"message number 2"* ]]
  [[ "$output" != *"message number 3"* ]]
}

@test "--truncate limits each message to N characters" {
  long="$(printf 'x%.0s' $(seq 1 500))"
  event "$SESSIONS_DIR/a.jsonl" "2026-07-11T13:00:00.000Z" "user" "$long"

  run_script "2026-07-11" --truncate 50

  # Header line + message + blank line; the message line is exactly 50 chars.
  message_line="$(grep '^x' <<<"$output")"
  [ "${#message_line}" -eq 50 ]
}

@test "default truncation is 400 characters" {
  long="$(printf 'x%.0s' $(seq 1 500))"
  event "$SESSIONS_DIR/a.jsonl" "2026-07-11T13:00:00.000Z" "user" "$long"

  run_script "2026-07-11"

  message_line="$(grep '^x' <<<"$output")"
  [ "${#message_line}" -eq 400 ]
}
