#!/usr/bin/env python3
"""session_summary.py: digest Claude Code session transcripts for a single date.

Emits the per-session, per-date user-message digest that the `xpquest-daily-log`
skill (Step 5) folds into the daily log. Extracted from the skill body so the
logic is versioned, reviewable, and covered by tests — see XP-Quest/.github#37.

Usage: session_summary.py YYYY-MM-DD [--sessions-dir DIR] [--max-messages N]
                                     [--truncate N]

Output (stdout), one block per session file that has messages on DATE:

    --- /abs/path/to/<session-uuid>.jsonl
    <message text>

    <message text>

Transcripts are JSONL; each line is one event carrying an ISO-8601 UTC
`timestamp`. Messages are bucketed by LOCAL calendar date, not by the raw UTC
prefix: `daily_git_summary.sh` groups commits with `date -d "$TARGET_DATE ..."`
in the local zone, and Robin's working day runs into the evening — past ~20:00
EDT (UTC-4) a message is already after midnight UTC, so UTC-prefix matching
shifts a whole evening of session bullets one day ahead of the commits they
belong with. `astimezone()` resolves the zone from TZ at runtime, so EST/EDT is
handled without a hardcoded offset.

Language note: this is Python, not bash like its sibling scripts. Parsing JSONL
with nested content blocks and unicode escapes is not something bash does safely,
and there is no `gh --jq` equivalent to lean on here (contrast daily_git_summary.sh,
which dropped its external jq dependency precisely because gh provides one).
"""

import argparse
import glob
import json
import os
import sys
from datetime import datetime

DEFAULT_SESSIONS_DIR = "~/.claude/projects/-home-rcoe-xpquest"
DEFAULT_MAX_MESSAGES = 5
DEFAULT_TRUNCATE = 400


def parse_args(argv):
    p = argparse.ArgumentParser(
        prog="session_summary.py",
        description="Digest Claude Code session transcripts for a single local date.",
    )
    p.add_argument("date", help="Local calendar date to digest (YYYY-MM-DD)")
    p.add_argument(
        "--sessions-dir",
        default=os.environ.get("XPQ_SESSIONS_DIR", DEFAULT_SESSIONS_DIR),
        help="Directory of *.jsonl transcripts (default: %(default)s)",
    )
    p.add_argument(
        "--max-messages",
        type=int,
        default=DEFAULT_MAX_MESSAGES,
        help="Messages to print per session (default: %(default)s)",
    )
    p.add_argument(
        "--truncate",
        type=int,
        default=DEFAULT_TRUNCATE,
        help="Truncate each message to N characters (default: %(default)s)",
    )
    return p.parse_args(argv)


def validate_date(value):
    try:
        datetime.strptime(value, "%Y-%m-%d")
    except ValueError:
        sys.stderr.write(
            f"Error: invalid date '{value}'. Expected format: YYYY-MM-DD\n"
        )
        raise SystemExit(1)
    return value


def local_date_of(timestamp):
    """ISO-8601 UTC timestamp -> local calendar date, or None if unparseable."""
    try:
        return (
            datetime.fromisoformat(timestamp.replace("Z", "+00:00"))
            .astimezone()
            .strftime("%Y-%m-%d")
        )
    except ValueError:
        return None


def message_text(event):
    """Human-typed text of a user event, or "" if it carries none.

    `content` is either a plain string or a list of typed blocks; only `text`
    blocks are human input (tool_result and friends are machine chatter).
    """
    content = event.get("message", {}).get("content", "")
    if isinstance(content, list):
        return " ".join(
            block.get("text", "")
            for block in content
            if isinstance(block, dict) and block.get("type") == "text"
        )
    return str(content)


def is_human_message(text):
    """Filter the injected envelopes out of the human-message stream.

    Hook payloads and tool-result blobs arrive on the same `type: user` channel
    as real input; they open with `<` (system-reminder / tool tags) or `[{`
    (serialized block arrays). Anything under 20 characters is an ack ("yes",
    "ok") that carries no narrative value.
    """
    return bool(text) and len(text) > 20 and not text.startswith("<") and not text.startswith("[{")


def collect(sessions_dir, date, truncate):
    """{session_path: [message, ...]} for sessions with messages on `date`."""
    sessions = {}
    pattern = os.path.join(os.path.expanduser(sessions_dir), "*.jsonl")
    for path in sorted(glob.glob(pattern)):
        messages = []
        try:
            handle = open(path, encoding="utf-8")
        except OSError as exc:
            sys.stderr.write(f"Warning: cannot read {path}: {exc}\n")
            continue
        with handle as f:
            for line in f:
                try:
                    event = json.loads(line)
                except (ValueError, TypeError):
                    continue  # partial/corrupt line: a live session is still being appended to
                if not isinstance(event, dict):
                    continue
                timestamp = event.get("timestamp", "")
                if not timestamp or local_date_of(timestamp) != date:
                    continue
                if event.get("type") != "user":
                    continue
                text = message_text(event).strip()
                if is_human_message(text):
                    messages.append(text[:truncate])
        if messages:
            sessions[path] = messages
    return sessions


def main(argv=None):
    args = parse_args(sys.argv[1:] if argv is None else argv)
    date = validate_date(args.date)

    sessions = collect(args.sessions_dir, date, args.truncate)
    for path, messages in sessions.items():
        print(f"--- {path}")
        for message in messages[: args.max_messages]:
            print(message)
            print()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
