---
name: xpquest-daily-log
description: Generate XP Quest daily_log and sred_daily_log (and, when the Time Tracker shows client work, a per-client client_daily_log) by merging git summaries, issue bodies, and Claude session history. Run as /xpquest-daily-log [YYYY-MM-DD] for one date, or with [--from DATE] [--to DATE] for a range. Skips dates already enriched; delete the file to force regeneration.
---

# xpquest-daily-log

Generate `daily_log-DATE.md` (complete development record), `sred_daily_log-DATE.md`
(audit-optimized SR&ED extraction), and — when the Time Tracker shows client work —
`client_daily_log-DATE.md` under a per-client subfolder, for the given date or date range.

The daily log covers ALL XP Quest development — engineering, administration, SR&ED. The SR&ED
log is an audit-optimized extraction from the same evidence. Client work is NOT XP Quest R&D:
it never appears in the daily or SR&ED logs and is written to a separate per-client log.

Tracked hours come from the XP Quest Time Tracker widget's Daily Summary, which
`daily_git_summary.sh` already folds into each day's `github_summary` as a prettified,
workstream-grouped `## Time Tracking` block (`xpq-eng*` → engineering, `xpq-sred*` → SR&ED,
anything else → client). This skill reads that block — it never parses the raw JSON (see Step 7).

**Anti-hallucination rule:** Populate only from actual evidence. Use `[fill in]` for qualitative
SR&ED fields that cannot be derived from commits, issue bodies, or session content. Omitting
a section is always better than inventing it. This is especially critical in SR&ED logs.

---

## Step 1: Generate git summaries via bash

The bash script handles date range resolution, git history gathering, and checkpoint management.
Do not reimplement this logic in the skill.

**Argument forms:**

| Form | Meaning |
| --- | --- |
| _(no args)_ | `[checkpoint, yesterday]` inclusive — requires a checkpoint file |
| `YYYY-MM-DD` | Single date |
| `--to DATE` | `[checkpoint, DATE]` inclusive |
| `--from DATE` | `[DATE, yesterday]` inclusive |
| `--from DATE --to DATE` | Explicit inclusive range |

Before calling the script, read the effective FROM and TO so you know which dates to iterate:

```bash
# Honors DAILY_LOG_CHECKPOINT env var; matches historical_git_summary.sh's default.
# Skill-owned state lives OUTSIDE the repo (~/.xpquest) so a branch switch or
# git clean can never delete it — see xpq-org #4.
CHECKPOINT_FILE="${DAILY_LOG_CHECKPOINT:-${HOME}/.xpquest/.daily-log-checkpoint}"
FROM=$(cat "$CHECKPOINT_FILE" 2>/dev/null || echo "")   # overridden by --from if supplied
TO=$(date -d yesterday +%Y-%m-%d)                        # overridden by --to if supplied
```

If the user passes `--checkpoint PATH` to the skill, set `CHECKPOINT_FILE=PATH` before reading
and forward the same flag to `historical_git_summary.sh` so the script's FROM matches the
pre-read.

If FROM is empty (no checkpoint) and `--from` was not supplied, do not call the script yet.
Ask the user to pick a start date with the message:

```text
No checkpoint found. Where would you like to start?
  1. Last week
  2. Yesterday
  3. Other — enter a date (YYYY-MM-DD or any expression accepted by GNU date)
```

Resolve the selection to a date string, set `--from` to that value, and proceed.

Call the bash script, passing any arguments through:

```bash
# no args, or --from/--to flags:
bash /home/rcoe/xpquest/xpq-org/scripts/historical_git_summary.sh [--from DATE] [--to DATE]

# single positional date — call the per-date script directly:
bash /home/rcoe/xpquest/xpq-org/scripts/daily_git_summary.sh DATE
```

`historical_git_summary.sh`:

- Reads `~/.xpquest/.daily-log-checkpoint` for the default FROM when `--from` is not supplied
- Calls `daily_git_summary.sh DATE` for each date, writing `github_summary-DATE.md` and a
  starter `daily_log-DATE.md` (marked `Session transcripts not included`)
- Updates the checkpoint to **today** (the run date) on completion
- Errors if no checkpoint exists and `--from` was not supplied

Use the FROM/TO values captured before the call to build the iteration list. Set per-date paths:

```text
LOGS_DIR="/home/rcoe/xpquest/xpq-project/Daily-Logs"
DAILY_LOG="${LOGS_DIR}/daily_log-${DATE}.md"
SRED_LOG="${LOGS_DIR}/sred_daily_log-${DATE}.md"
GITHUB_SUMMARY="${LOGS_DIR}/github_summary-${DATE}.md"
# Client logs live one level down, per client (Step 11):
#   ${LOGS_DIR}/<Client Name>/client_daily_log-${DATE}.md
```

---

## Step 2: Check enrichment status

For each DATE, check whether enrichment is needed before doing any Claude work:

- Skip if `daily_log-DATE.md` exists **and** does not contain `"Session transcripts not included"`
  **and** (no SR&ED content was classified for this date OR `sred_daily_log-DATE.md` exists) —
  it has been enriched; mark as `exists` and move on.
- Proceed if the daily log is missing, contains the bash-only-draft marker, or contains
  SR&ED-eligible content but the companion `sred_daily_log-DATE.md` is missing. The last case
  catches dates that were enriched before SR&ED extraction was implemented or where the
  SR&ED log was deleted to force regeneration.

Print `=== Processing DATE ===` before each date that requires enrichment.

---

## Step 3: Read git summary

Read `$GITHUB_SUMMARY`. If the file does not exist, there were no commits for this date;
proceed without commit data (session and meeting content alone may still warrant a log).

---

## Step 4: Fetch issue context (PM/architecture narrative)

For each GitHub issue reference `#NN` found in `$GITHUB_SUMMARY`, extract the issue body:

```bash
gh issue view <NN> --repo XP-Quest/<repo> \
  --json title,body,labels \
  --jq '{title:.title, first_line:(.body//""|split("\n")|map(select(length>2))|first//""), labels:[.labels[].name]}'
```

Cache results by `repo#NN`. Use `first_line` to write "why" context, not just "what".

---

## Step 5: Read Claude session history for this date

Discover sessions by message-level `timestamp` inside each JSONL — not by file mtime.
A session started one day and resumed the next would otherwise be misattributed to the
resume day, silently dropping the original day's content.

Bucket by **local calendar date, not raw UTC**. Git commits are grouped by `daily_git_summary.sh`
using the local system timezone (`date -d "$TARGET_DATE 00:00:00"`), and Robin's working day
runs into the evening — anything after ~8pm EDT (UTC-4) already falls after midnight UTC, so
a naive UTC-prefix match systematically shifts an entire evening's session bullets one calendar
day ahead of the commits they belong with. Convert with `astimezone()` (no hardcoded offset, so
it tracks EST/EDT automatically) before comparing dates.

```python
import json, glob, os
from datetime import datetime

DATE = "YYYY-MM-DD"  # local calendar date — matches daily_git_summary.sh's bucketing
sessions_by_file = {}
for path in sorted(glob.glob(os.path.expanduser(
        "~/.claude/projects/-home-rcoe-xpquest/*.jsonl"))):
    msgs = []
    with open(path) as f:
        for line in f:
            try:
                obj = json.loads(line)
                ts = obj.get('timestamp', '')
                if not ts:
                    continue
                local_date = datetime.fromisoformat(ts.replace('Z', '+00:00')).astimezone().strftime('%Y-%m-%d')
                if local_date != DATE:
                    continue
                if obj.get('type') != 'user':
                    continue
                content = obj.get('message', {}).get('content', '')
                if isinstance(content, list):
                    text = ' '.join(c.get('text', '') for c in content if c.get('type') == 'text')
                else:
                    text = str(content)
                text = text.strip()
                if text and len(text) > 20 and not text.startswith('<') and not text.startswith('[{'):
                    msgs.append(text[:400])
            except Exception:
                pass
    if msgs:
        sessions_by_file[path] = msgs
for path, msgs in sessions_by_file.items():
    print(f"--- {path}")
    for m in msgs[:5]:
        print(m)
        print()
```

Notes:

- The `timestamp` field on each line is ISO 8601 UTC; convert to local time before bucketing (see above) rather than comparing the raw string prefix.
- One JSONL may contribute to multiple daily logs (sessions that genuinely span local midnight, or sessions resumed on a later day). That's correct — emit per-date bullets independently.
- The `< … >` / `[{ … }]` filters drop system-injected tool-result and hook envelopes from the human-message stream.

For each session file with matching messages:

- Skip sessions with no XP Quest content (no references to xpq-*, WP1-6, SR&ED, the product, or XPQ tooling)
- For relevant sessions, write one concise bullet summarizing what was worked on
- Classify each as: Engineering / R&D | Administration | Accounting / Legal / Consulting

---

## Step 6: Read meeting notes

Glob: `/home/rcoe/xpquest/xpq-project/Meetings/${DATE}-*.md`

Read each. Extract frontmatter fields: `category`, `attendees`, `topic`. Skip if none found.

---

## Step 7: Read Time Tracker hours (from the git summary)

`daily_git_summary.sh` (Step 1) already folds the XP Quest Time Tracker widget's per-project
hours into `$GITHUB_SUMMARY` as a prettified, workstream-grouped `## Time Tracking` block.
Read it straight from there — **do not parse any JSON and do not re-resolve the `.xpquest`
directory; the bash script already did both.**

Extract the `## Time Tracking` section from `$GITHUB_SUMMARY`. If it is absent, the widget
summary for this date didn't exist — there are no tracked hours for this date; proceed without them.

The block is already split into three subsections. Route each one as-is, copying its bullets
through **verbatim** (each is already human-readable:
`- **[code] name** — H:MM — description (client)`):

- **`### Engineering / R&D`** → fold into the **Engineering / R&D** section of the daily log (Step 9).
- **`### SR&ED`** → fold into the SR&ED log's **Work Performed** and roll the hours into
  **Hours Logged** (Step 10).
- **`### Client`** → do NOT put these in the XP Quest daily/SR&ED logs; hold them for the
  per-client log (Step 11).

**XP Quest internal-tooling code (`xpq-techops`):** work on XPQ's own utilities (e.g. the
Time Tracker, dev/ops tooling) is logged under the `xpq-techops` project code. It is XPQ
**engineering** — fold it into the **Engineering / R&D** section. These entries are
intentionally lightweight: a bullet referencing just the project **code and name** (plus any
tracker description) is sufficient — do not require a GitHub issue link or per-commit
breakdown. If correlating commits happen to surface (e.g. in `rdcoe/timetracking`) you may
list them, but their absence is expected and fine.

**Ask when time isn't obviously XPQ-correlatable.** If a `## Time Tracking` entry cannot be
confidently tied to XP Quest from its code/name/description plus the day's commits and
sessions (e.g. an unfamiliar code, or `xpq-eng` hours with no matching XPQ evidence anywhere),
do NOT guess its workstream or silently file it — pause and ask Robin which XPQ work (or
client) the time belongs to before writing the log. Recognized codes (`xpq-eng*`, `xpq-sred*`,
`xpq-techops`) don't need this; only genuinely ambiguous entries do.

The `**Total tracked:**` line is the day's overall tracked hours — use it for the Step 12 report.

---

## Step 8: Classify SR&ED content

Apply WP classification to all content (commits, issue bodies, session bullets):

| WP  | Title                                   | Keywords                                                             |
|-----|-----------------------------------------|----------------------------------------------------------------------|
| WP1 | Semantic Chunking                       | chunk, segmenter, segmentation, multi-domain, résumé parsing         |
| WP2 | Relevance Gate Threshold Calibration    | relevance gate, threshold, calibration, semantic similarity, holdout |
| WP3 | Ambiguity Detection                     | ambiguity, unanswerable, domain heuristic, clarifying question       |
| WP4 | Conversational Augmentation             | conversational, augmentation, ExperienceEntry, interview, dialog     |
| WP5 | Dual-Score Correlation Engine           | dual-score, job description correlation, scoring engine, weighting   |
| WP6 | Multi-Tenant Quota / Cost Attribution   | quota, cost attribution, multi-tenant, backpressure, LLM cost        |

---

## Step 9: Write daily_log-DATE.md

If zero content (no commits, no sessions, no meetings) → print "Nothing to log for DATE" and skip.

Otherwise write `$DAILY_LOG`:

```markdown
# XP Quest — Daily Log — DATE

**Summary:** one paragraph synthesizing the day's focus from actual evidence only.

## Engineering / R&D

- **repo** [#NN: issue title](github-url)
  first_line of issue body — the "why"
  - `sha`: commit message
  - session bullet if this issue was also discussed in a session

## SR&ED Activity

_SR&ED work logged — see sred_daily_log-DATE.md for detail._

- **WPN** (WP title): brief pointer to what was touched

## Administration

- admin session bullet

## Accounting / Legal / Consulting

- Met with attendees re: topic [category]

---
*Generated by xpquest-daily-log — DATE*
```

Rules:

- Omit any section with no evidence
- Group commits under their issue; use issue first_line as the "why"
- Do NOT include any GitHub PAT or credential

Save with Write tool.

---

## Step 10: Write sred_daily_log-DATE.md

Skip if no SR&ED content found.

Otherwise write `$SRED_LOG`, grouping by WP with `---` between blocks:

```markdown
# XP Quest — SR&ED Daily Log — DATE

### DATE — one-line focus derived from evidence

**Hours Logged:** from the Time Tracking SR&ED bullets (Step 7), else [fill in]
**Work Category:** Software Development | System Design | Algorithm Research | Testing & Validation | Documentation of R&D
**Work Package:** WPN — WP title

**Technological Uncertainty:**
[fill in]

**Hypothesis:**
[fill in]

**Work Performed:**

- **repo** `sha`: commit message
- session bullet if applicable

**Outcome / Result:**
[fill in]

**Advancement of Knowledge:**
[fill in]

**Supporting Evidence:**

- GitHub: `sha` — [#NN](url) repo — commit message
- Time Tracker: hours from the `## Time Tracking` SR&ED bullets, if present
```

Rules:

- `[fill in]` for ALL qualitative fields — do not invent narrative
- Work Performed and Supporting Evidence: actual commits and session content only
- Do NOT include any GitHub PAT or credential

Save with Write tool.

---

## Step 11: Write client_daily_log-DATE.md

Client work is NOT XP Quest R&D and must never appear in the daily or SR&ED logs — it is
logged separately for billing/record-keeping. Build this from the `### Client` subsection of
the `## Time Tracking` block (Step 7).

If there is no `### Client` subsection for the date → skip; write nothing.

Otherwise group the client bullets **by client** (the client name in parentheses on each
bullet; fall back to the code's prefix if absent). Write one file per client, one level under
`$LOGS_DIR` in a folder named for the (sanitized — see rule below) client:

```text
${LOGS_DIR}/<sanitized Client Name>/client_daily_log-${DATE}.md
```

Create the client folder if it does not exist. File contents:

```markdown
# Client Work — <Client Name> — Daily Log — DATE

- **[code] name** — H:MM — description (client)
```

Rules:

- **Sanitize the client subfolder name — never `$LOGS_DIR` itself.** The client name comes
  from untrusted Tracker data and may contain path-breaking characters. Derive the folder by
  replacing `/ \ : * ? " < > |` and control characters (and trimming leading/trailing dots and
  whitespace) with `-`. **Preserve internal spaces** — they are valid on both Windows and Linux
  (the `$LOGS_DIR` base path already contains one); do not collapse them. The heading inside the
  file (`# Client Work — <Client Name> …`) keeps the original, unsanitized name.
- Populate ONLY from the `### Client` bullets — they already carry code, name, H:MM,
  description, and client on a single line; copy each through verbatim, just regrouped under
  the client folder/heading.
- Do NOT pull in commits, sessions, or SR&ED narrative — this log is hours + the project's
  own name/description only.
- Do NOT include any GitHub PAT or credential.

Save each with the Write tool.

---

## Step 12: Report

Print per date:

```text
Date:       DATE
Daily log:  created | enriched | skipped (no content) | exists (already enriched) — path
SR&ED log:  created | skipped (no SR&ED content) | exists — path
Client log: created (per client) | skipped (no client work) — path(s)
Sessions:   N found, M relevant
Commits:    N tracked, M SR&ED
Tracker:    Total tracked from the Time Tracking block, or "no time tracked"
```

The checkpoint was already updated to today by `historical_git_summary.sh` in Step 1.
