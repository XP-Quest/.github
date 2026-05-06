---
name: xpquest-daily-log
description: Generate XP Quest daily_log and sred_daily_log by merging git summaries, issue bodies, and Claude session history. Run as /xpquest-daily-log [YYYY-MM-DD] for one date, or /xpquest-daily-log --from YYYY-MM-DD [--to YYYY-MM-DD] for a range. Always writes/overwrites — use xpquest-backfill-logs to skip already-complete dates.
---

Generate `daily_log-<DATE>.md` (complete development record) and `sred_daily_log-<DATE>.md`
(audit-optimized extraction of SR&ED work only) for the given date.

The daily log covers ALL development — engineering, administration, SR&ED. The SR&ED log is
not a separate workflow; it is extracted from the same evidence to make CRA auditing simpler.

**Anti-hallucination rule:** Populate only from actual evidence. Use `[fill in]` for qualitative
SR&ED fields that cannot be derived from commits, issue bodies, or session content. Omitting
a section is always better than inventing it. This is especially critical in SR&ED logs.

---

## Step 1: Resolve date or date range

Parse arguments:

| Form | Meaning |
| --- | --- |
| _(no args)_ | Single date: yesterday |
| `YYYY-MM-DD` (positional) | Single date: that date |
| `--from DATE` | Range start (inclusive); `--to` defaults to yesterday |
| `--to DATE` | Range end (inclusive); `--from` defaults to `--to` (single date) |
| `--from DATE --to DATE` | Explicit range |

Resolve dates:
```bash
# default FROM and TO
FROM=$(date -d yesterday +%Y-%m-%d)
TO=$(date -d yesterday +%Y-%m-%d)
# override from parsed args, then normalise with GNU date for flexible formats
FROM=$(date -d "$FROM" +%Y-%m-%d)
TO=$(date -d "$TO"   +%Y-%m-%d)
```

Validate: if FROM is after TO, stop with an error.

Generate the list of dates to process (inclusive):
```bash
current="$FROM"
while [[ $(date -d "$current" +%s) -le $(date -d "$TO" +%s) ]]; do
  echo "$current"
  current=$(date -d "$current + 1 day" +%Y-%m-%d)
done
```

For each DATE in the list, execute Steps 2–9 below. When processing more than one date,
print `=== Processing DATE ===` before each. Always write/overwrite — this skill does not
skip already-complete logs (use `/xpquest-backfill-logs` if you want skip behaviour).

Set per-date paths:

```text
DAILY_LOG="/home/rcoe/xpquest/xpq-project/Daily Logs/daily_log-${DATE}.md"
SRED_LOG="/home/rcoe/xpquest/xpq-project/Daily Logs/sred_daily_log-${DATE}.md"
GITHUB_SUMMARY="/home/rcoe/xpquest/xpq-project/Daily Logs/github_summary-${DATE}.md"
```

---

## Step 2: Load or generate git summary

Check whether `$GITHUB_SUMMARY` exists.

If missing, generate it:
```bash
bash /home/rcoe/xpquest/xpq-org/scripts/daily_git_summary.sh "$DATE"
```

Re-check. If still missing, there are no commits for this date. Proceed without commit data
(session and meeting content alone may still warrant a log).

---

## Step 3: Fetch issue context (PM/architecture narrative)

For each GitHub issue reference `#NN` found in `$GITHUB_SUMMARY`, extract the issue body
to understand the purpose and architectural context:
```bash
gh issue view <NN> --repo XP-Quest/<repo> \
  --json title,body,labels \
  --jq '{title:.title, first_line:(.body//""|split("\n")|map(select(length>2))|first//""), labels:[.labels[].name]}'
```

Cache results by `repo#NN`. The `first_line` gives the hypothesis or description behind the commit.
Use it to write "why" context in the daily log, not just "what".

---

## Step 4: Read Claude session history for this date

Find session files modified on DATE:
```bash
find ~/.claude/projects/-home-rcoe-xpquest/ -name "*.jsonl" \
  -newermt "${DATE} 00:00:00" ! -newermt "${DATE} 23:59:59" | sort
```

For each file found, extract user messages (the prompts describe what was being worked on):
```python
import json, sys

sessions = []
with open(JSONL_PATH) as f:
    for line in f:
        try:
            obj = json.loads(line)
            if obj.get('type') == 'user':
                msg = obj.get('message', {})
                content = msg.get('content', '')
                if isinstance(content, list):
                    text = ' '.join(c.get('text','') for c in content if c.get('type')=='text')
                else:
                    text = str(content)
                text = text.strip()
                if text and len(text) > 20:
                    sessions.append(text[:300])
        except:
            pass
# Print first 5 user messages to understand session topic
for s in sessions[:5]:
    print(s)
```

For each session file:
- Read user messages to determine the session topic
- Skip sessions with no XP Quest content (no references to xpq-*, WP1-6, SR&ED, the product, or XPQ tooling)
- For relevant sessions, write one concise bullet summarizing what was worked on
- Classify each session as: Engineering / R&D | Administration | Accounting / Legal / Consulting

---

## Step 5: Read meeting notes

Glob: `/home/rcoe/xpquest/xpq-project/Meetings/${DATE}-*.md`

Read each. Extract frontmatter fields: `category`, `attendees`, `topic`.
If no Meetings directory or no files for this date, skip.

---

## Step 6: Read time log

```bash
grep "^${DATE}" /home/rcoe/xpquest/xpq-org/journal/.time-log.csv 2>/dev/null || true
```

Format: `date\tissue\trepo\twp\tstart\tstop\thours`

Collect any matching rows — used to populate "Hours Logged" in SR&ED entries.

---

## Step 7: Classify SR&ED content

Apply this WP classification to ALL content (commit messages, issue bodies, session bullets)
using keyword matching. Work matching any WP is SR&ED; all other engineering is non-SR&ED.

| WP  | Title                                   | Keywords                                                             |
|-----|-----------------------------------------|----------------------------------------------------------------------|
| WP1 | Semantic Chunking                       | chunk, segmenter, segmentation, multi-domain, résumé parsing         |
| WP2 | Relevance Gate Threshold Calibration    | relevance gate, threshold, calibration, semantic similarity, holdout |
| WP3 | Ambiguity Detection                     | ambiguity, unanswerable, domain heuristic, clarifying question       |
| WP4 | Conversational Augmentation             | conversational, augmentation, ExperienceEntry, interview, dialog     |
| WP5 | Dual-Score Correlation Engine           | dual-score, job description correlation, scoring engine, weighting   |
| WP6 | Multi-Tenant Quota / Cost Attribution   | quota, cost attribution, multi-tenant, backpressure, LLM cost        |

---

## Step 8: Write daily_log-<DATE>.md

If zero content across all sections (no commits, no sessions, no meetings) → print
"Nothing to log for ${DATE}" and stop. Do not write any file.

Otherwise write `$DAILY_LOG`:

```
# XP Quest — Daily Log — <DATE>

**Summary:** <one paragraph — synthesize the day's focus from actual evidence: commits,
issue context, sessions, meetings. Write only what the evidence supports. Do not pad.>

## Engineering / R&D

- **<repo>** [#NN: <issue title>](<github-url>)
  <first_line of issue body as PM context — the "why">
  - `<sha>`: <commit message>
  - <session bullet if this issue was also discussed in a session>

- <session bullet for engineering work not tied to a specific commit>

## SR&ED Activity

_SR&ED work logged — see `sred_daily_log-<DATE>.md` for detail._

- **WP<N>** (<WP title>): <brief pointer to what was touched, e.g. "chunker threshold experiment">

## Administration

- <admin session bullet>

## Accounting / Legal / Consulting

- Met with <attendees> re: <topic> [<category>]

---
*Generated by xpquest-daily-log — <DATE>*
```

Rules:
- Omit any section with no evidence
- Omit SR&ED Activity section if no SR&ED work found
- Group commits under their issue, not repo; use issue link as the heading
- Use issue first_line to explain purpose (the PM/architecture "why"), not just the commit message
- Do NOT include any GitHub PAT or credential

Save with Write tool.

---

## Step 9: Write sred_daily_log-<DATE>.md

If no SR&ED content was found across all sources → skip, do not write file.

Otherwise write `$SRED_LOG`. Group by WP; separate multiple WP blocks with `---`.

```
# XP Quest — SR&ED Daily Log — <DATE>

### <DATE> — <one-line focus derived only from evidence>

**Hours Logged:** <from time log if present, else [fill in]>
**Work Category:** <Software Development | System Design | Algorithm Research | Testing & Validation | Documentation of R&D — infer from evidence; use [fill in] if unclear>
**Work Package:** WP<N> — <WP title from table above>

**Technological Uncertainty:**
[fill in — if issue body contains a hypothesis or uncertainty statement, quote it here]

**Hypothesis:**
[fill in — use issue body hypothesis field if present; otherwise [fill in]]

**Work Performed:**
- **<repo>** `<sha>`: <commit message>
- <session bullet if applicable>

**Outcome / Result:**
[fill in]

**Advancement of Knowledge:**
[fill in]

**Supporting Evidence:**
- GitHub: `<sha>` — [#NN](<url>) <repo> — <commit message>
- Time log: <hours, start–stop UTC if present>
```

Rules:
- `[fill in]` for ALL qualitative fields (Uncertainty, Hypothesis, Outcome, Advancement)
- Work Performed and Supporting Evidence: populate ONLY from actual commits and session content
- Do not invent narrative — CRA will compare this against git history
- Do NOT include any GitHub PAT or credential

Save with Write tool.

---

## Step 10: Report

Print:
```
Date:       <DATE>
Daily log:  <created | enriched (replaced bash draft) | skipped (no content)> — <path>
SR&ED log:  <created | skipped (no SR&ED content)> — <path>
Sessions:   <N session file(s) found, M relevant>
Commits:    <N tracked, M SR&ED>
```
