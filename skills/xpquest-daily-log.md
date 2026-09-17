---
name: xpquest-daily-log
description: Generate XP Quest daily_log and sred_daily_log (and, when the Time Tracker shows client work, a per-client client_daily_log) by merging git summaries, issue bodies, and Claude session history. Run as /xpquest-daily-log [YYYY-MM-DD] for one date, or with [--from DATE] [--to DATE] for a range. Merges new host-local evidence into existing enriched dates when present.
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

## Step 0: Confirm Time Tracker export

`daily_git_summary.sh` (Step 1) locates Time Tracker hours by looking for
`daily-summary-DATE.json`, a file the XP Quest Time Tracker widget writes on export. If that
file is missing for a date in scope, the script does not error — it silently omits the
`## Time Tracking` block, and the resulting daily/SR&ED logs get generated with no tracked
hours and no warning (see XP-Quest/.github#47).

Before calling the script, **ask Robin and block on his answer**:

    Have you exported the Time Tracker Daily Summary for the date(s) in scope? [y/n]

- If yes (`y`/`yes`), proceed to Step 1.
- If no, unanswered, or anything else, stop here. Tell him to export from the widget first, then re-run the skill. Do not call `historical_git_summary.sh`/`daily_git_summary.sh` until he confirms.

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

`Daily-Logs/` lives in the shared OneDrive folder both machines read and write (see
XP-Quest/.github#41), but the Time Tracker JSON and Claude session transcripts that feed it
do **not** — each machine only ever sees its own. So a date already enriched by one machine
is not necessarily complete: the other machine may hold session evidence for that same date
that has never been folded in. Never sync those raw per-machine inputs to make them mutually
visible — the shared output files are the accumulation point, not the inputs (Robin's call,
2026-09-15: syncing raw JSON/jsonl wasn't worth building; a solid merge on read is enough).

For each DATE, classify status before doing any Claude work:

- **missing / starter** — `daily_log-DATE.md` doesn't exist, or still contains
  `"Session transcripts not included"`. Proceed in **fresh** mode (Step 9/10/11 write the
  file from scratch, as today).
- **enriched, SR&ED gap** — `daily_log-DATE.md` is enriched but classifies SR&ED-eligible
  content while `sred_daily_log-DATE.md` is missing. Proceed in fresh mode for the SR&ED log
  only (Step 10); the daily log itself still goes through the merge check below, since this
  case can co-occur with new session evidence from this host.
- **enriched, no gap** — run Step 5 (session digest) for this host now. If it prints nothing,
  this host has no local evidence not already reflected — git commits and Time Tracking are
  already host-independent by the time they reach this skill (daily_git_summary.sh
  cross-host-merges Time Tracking itself; commits are identical from any host that has
  fetched), so there is nothing left this host could add. Mark `exists` and move on. If it
  prints session content, proceed in **merge** mode (Step 9/10/11 read-then-add-delta, never
  a full `Write`).

Print `=== Processing DATE ===` before each date that requires fresh or merge-mode work.

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

Call the script — do not reimplement this logic in the skill:

```bash
python3 /home/rcoe/xpquest/xpq-org/scripts/session_summary.py "$DATE"
```

It prints one block per session file that has messages on DATE:

```text
--- /home/rcoe/.claude/projects/-home-rcoe-xpquest/<session-uuid>.jsonl
<message text>

<message text>
```

Empty output means no session activity on that date; proceed without session content.

`session_summary.py`:

- Discovers sessions by message-level `timestamp` inside each JSONL — not by file mtime, so a
  session started one day and resumed the next is not misattributed to the resume day.
- Buckets by **local calendar date, not raw UTC**, matching how `daily_git_summary.sh` groups
  commits. (Anything after ~8pm EDT already falls after midnight UTC; a naive UTC-prefix match
  shifts an entire evening's session bullets one calendar day ahead of the commits they belong
  with.)
- Drops everything the harness synthesized rather than Robin typing: `isMeta` events (a slash
  command injects the invoked skill's own SKILL.md body as a user message), `< … >` tool/hook
  payloads, `[{ … }]` block arrays, `[Request interrupted by user…]` markers, and
  acknowledgements of 20 characters or fewer.
- Prints the first 5 messages per session, each truncated to 400 characters. Override with
  `--max-messages N` / `--truncate N` when a date needs more detail.

Everything the script prints is therefore Robin's own input — take it at face value.

Notes:

- One JSONL may contribute to multiple daily logs (sessions that genuinely span local midnight,
  or sessions resumed on a later day). That's correct — emit per-date bullets independently.

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

**Merge mode** (Step 2 classified this date `enriched, no gap` with new session content — a
second machine adding to a date the first machine already wrote): do not `Write` a fresh file.
`Read` the existing `$DAILY_LOG` first, then use `Edit` to add only what this host's evidence
(Step 5's session digest, plus any commit not already present verbatim — see Step 2) contributes
that is not already there:

- Dedup commits by SHA already appearing in the file; dedup session bullets by the session file
  path from Step 5's `--- path` header or by clear overlap with an existing bullet's text.
- Insert new bullets **into the existing matching group** — under the same `**repo**
  [#NN: ...]` issue block if one is already present, or as a new issue block appended within
  its existing section (`## Engineering / R&D`, `## SR&ED Activity`, etc.) if not. Follow
  Robin's instruction: merged content stays organized **by section/issue, the same way a
  single-machine run would organize it** — never partitioned into a device-specific block
  (no "## From flash" / "## Antman's additions").
- If a section the new content belongs in doesn't exist yet in the file, add it in its normal
  template position (Step 9's section order below), not appended at the end out of order.
- Never remove, reorder, or rewrite content that's already there. Leave the `**Summary:**` line
  as-is unless the new evidence changes the day's overall focus enough to be misleading, in
  which case extend it with a short clause rather than rewriting it wholesale.
- If, after dedup, there is nothing left to add, skip silently — this is the idempotent no-op
  case (e.g. the same host re-running with no new evidence).

**Fresh mode** (missing, starter, or first enrichment): write `$DAILY_LOG`:

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

**Merge mode**: `Read` the existing `$SRED_LOG` first, then `Edit` in only the delta — same
dedup rule as Step 9 (by SHA / session path). Two things are load-bearing here:

- **Never overwrite a qualitative field Robin has already filled in** — `Technological
  Uncertainty`, `Hypothesis`, `Outcome / Result`, `Advancement of Knowledge`. If a field still
  literally reads `[fill in]`, leave it that way; it is still pending his input, not "safe to
  invent because it's a placeholder." These fields are primary claim narrative evidence — see
  CLAUDE.md §10's note on contemporaneous documentation — and a merge run silently clobbering
  Robin's own words would be far worse than the skip-on-overwrite bug this feature replaces.
- **Work Performed** and **Supporting Evidence** are additive lists — append new bullets not
  already present, in place, same as Step 9.
- **Hours Logged** is machine-derived (from the Step 7 SR&ED Time Tracking bullets, which
  `daily_git_summary.sh` already cross-host-sums) — safe to refresh even in merge mode if the
  merged total changed.

If no new WP block or bullet survives dedup, skip silently.

**Fresh mode**: write `$SRED_LOG`, grouping by WP with `---` between blocks:

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
the `## Time Tracking` block (Step 7). That block is already cross-host-summed per client
`code` by `daily_git_summary.sh` (see XP-Quest/.github#41), so client hour lines need no
extra host-merge handling here.

**Merge mode**: `Read` the existing per-client `client_daily_log-DATE.md` first (if it
exists) and `Edit` in only bullets not already present verbatim — same additive, no-overwrite
approach as Steps 9/10. If a client subfolder/file this host's data belongs in doesn't exist
yet, create it as in fresh mode.

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
Daily log:  created | merged (+N bullets) | skipped (no content) | exists (already enriched, nothing new) — path
SR&ED log:  created | merged (+N bullets) | skipped (no SR&ED content) | exists — path
Client log: created (per client) | merged (per client) | skipped (no client work) — path(s)
Sessions:   N found, M relevant
Commits:    N tracked, M SR&ED
Tracker:    Total tracked from the Time Tracking block, or "no time tracked"
```

The checkpoint was already updated to today by `historical_git_summary.sh` in Step 1.
