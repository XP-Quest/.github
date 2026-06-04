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
anything else → client). This skill reads that block — it never parses the raw JSON (see Step 8).

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
CHECKPOINT_FILE="${DAILY_LOG_CHECKPOINT:-/home/rcoe/xpquest/xpq-org/journal/.daily-log-checkpoint}"
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

- Reads `journal/.daily-log-checkpoint` for the default FROM when `--from` is not supplied
- Calls `daily_git_summary.sh DATE` for each date, writing `github_summary-DATE.md` and a
  starter `daily_log-DATE.md` (marked `Session transcripts not included`)
- Updates the checkpoint to **today** (the run date) on completion
- Errors if no checkpoint exists and `--from` was not supplied

Use the FROM/TO values captured before the call to build the iteration list. Set per-date paths:

```text
LOGS_DIR="/home/rcoe/xpquest/xpq-project/Daily Logs"
DAILY_LOG="${LOGS_DIR}/daily_log-${DATE}.md"
SRED_LOG="${LOGS_DIR}/sred_daily_log-${DATE}.md"
GITHUB_SUMMARY="${LOGS_DIR}/github_summary-${DATE}.md"
# Client logs live one level down, per client (Step 12):
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

```python
import json, glob, os

DATE = "YYYY-MM-DD"  # UTC; matches the leading characters of each entry's `timestamp`
sessions_by_file = {}
for path in sorted(glob.glob(os.path.expanduser(
        "~/.claude/projects/-home-rcoe-xpquest/*.jsonl"))):
    msgs = []
    with open(path) as f:
        for line in f:
            try:
                obj = json.loads(line)
                if not obj.get('timestamp', '').startswith(DATE):
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

- The `timestamp` field on each line is ISO 8601 UTC. Compare by string prefix against `YYYY-MM-DD`.
- One JSONL may contribute to multiple daily logs (sessions that span midnight UTC, or sessions resumed across days). That's correct — emit per-date bullets independently.
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

## Step 7: Read time log

```bash
grep "^${DATE}" /home/rcoe/xpquest/xpq-org/journal/.time-log.csv 2>/dev/null || true
```

Format: `date\tissue\trepo\twp\tstart\tstop\thours` — used to populate "Hours Logged" in SR&ED entries.

---

## Step 8: Read Time Tracker hours (from the git summary)

`daily_git_summary.sh` (Step 1) already folds the XP Quest Time Tracker widget's per-project
hours into `$GITHUB_SUMMARY` as a prettified, workstream-grouped `## Time Tracking` block.
Read it straight from there — **do not parse any JSON and do not re-resolve the `.xpquest`
directory; the bash script already did both.**

Extract the `## Time Tracking` section from `$GITHUB_SUMMARY`. If it is absent, the widget
summary for this date didn't exist — skip this step and fall back to `.time-log.csv` (Step 7)
alone.

The block is already split into three subsections. Route each one as-is, copying its bullets
through **verbatim** (each is already human-readable:
`- **[code] name** — H:MM — description (client)`):

- **`### Engineering / R&D`** → fold into the **Engineering / R&D** section of the daily log (Step 10).
- **`### SR&ED`** → fold into the SR&ED log's **Work Performed** and roll the hours into
  **Hours Logged** (Step 11), alongside any `.time-log.csv` rows.
- **`### Client`** → do NOT put these in the XP Quest daily/SR&ED logs; hold them for the
  per-client log (Step 12).

The `**Total tracked:**` line is the day's overall tracked hours — use it for the Step 13 report.

---

## Step 9: Classify SR&ED content

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

## Step 10: Write daily_log-DATE.md

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

## Step 11: Write sred_daily_log-DATE.md

Skip if no SR&ED content found.

Otherwise write `$SRED_LOG`, grouping by WP with `---` between blocks:

```markdown
# XP Quest — SR&ED Daily Log — DATE

### DATE — one-line focus derived from evidence

**Hours Logged:** from time log, else [fill in]
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
- Time log: hours, start–stop UTC if present
```

Rules:

- `[fill in]` for ALL qualitative fields — do not invent narrative
- Work Performed and Supporting Evidence: actual commits and session content only
- Do NOT include any GitHub PAT or credential

Save with Write tool.

---

## Step 12: Write client_daily_log-DATE.md

Client work is NOT XP Quest R&D and must never appear in the daily or SR&ED logs — it is
logged separately for billing/record-keeping. Build this from the `### Client` subsection of
the `## Time Tracking` block (Step 8).

If there is no `### Client` subsection for the date → skip; write nothing.

Otherwise group the client bullets **by client** (the client name in parentheses on each
bullet; fall back to the code's prefix if absent). Write one file per client, one level under
`$LOGS_DIR` in a folder named for the client:

```text
${LOGS_DIR}/<Client Name>/client_daily_log-${DATE}.md
```

Create the client folder if it does not exist. File contents:

```markdown
# Client Work — <Client Name> — Daily Log — DATE

- **[code] name** — H:MM
  description
```

Rules:

- Populate ONLY from the `### Client` bullets — they already carry code, name, H:MM,
  description, and client; copy them through, just regrouped under the client folder/heading.
- Do NOT pull in commits, sessions, or SR&ED narrative — this log is hours + the project's
  own name/description only.
- Do NOT include any GitHub PAT or credential.

Save each with the Write tool.

---

## Step 13: Report

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
