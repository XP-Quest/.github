---
name: xpquest-backfill-logs
description: Backfill XP Quest daily_log and sred_daily_log for each date in a range that has a github_summary but no enriched daily_log yet. Run as /xpquest-backfill-logs [--from YYYY-MM-DD] [--to YYYY-MM-DD].
---

Backfill XP Quest daily logs for a date range. For each date, generate files that are
missing or were only bash-generated (not yet enriched with session context).

**Anti-hallucination rule:** Same as xpquest-daily-log — populate only from evidence.
Use `[fill in]` for qualitative SR&ED fields. Never fabricate content.

---

## Step 1: Resolve date range

Parse arguments:
- `--from DATE`: start date (inclusive). Defaults to the checkpoint:
  ```bash
  cat /home/rcoe/xpquest/xpq-org/journal/.daily-log-checkpoint 2>/dev/null || echo "required"
  ```
  If no checkpoint and no `--from`, stop with: "Provide --from DATE to set start date."

- `--to DATE`: end date (inclusive). Defaults to yesterday:
  ```bash
  date -d yesterday +%Y-%m-%d
  ```

Validate: `--from` must not be after `--to`. If equal, process one date.

Generate the date list:
```bash
current="$FROM"
while [[ $(date -d "$current" +%s) -le $(date -d "$TO" +%s) ]]; do
  echo "$current"
  current=$(date -d "$current + 1 day" +%Y-%m-%d)
done
```

---

## Step 2: For each date

Process oldest to newest. For each `<DATE>`:

### 2a. Determine what's needed

Check:
- `GITHUB_SUMMARY="/home/rcoe/xpquest/xpq-project/Daily Logs/github_summary-${DATE}.md"`
- `DAILY_LOG="/home/rcoe/xpquest/xpq-project/Daily Logs/daily_log-${DATE}.md"`
- `SRED_LOG="/home/rcoe/xpquest/xpq-project/Daily Logs/sred_daily_log-${DATE}.md"`

Determine status for each:
- `DAILY_LOG` needs enrichment if: missing, OR contains `"Session transcripts not included"`
  (indicating it is a bash-only draft)
- `SRED_LOG` needs generation if: missing

If BOTH are complete (daily_log enriched + sred_log exists or no SR&ED content expected) → mark
date as `exists`, skip to next date.

### 2b. Generate github_summary if missing

If `$GITHUB_SUMMARY` is missing:
```bash
bash /home/rcoe/xpquest/xpq-org/scripts/daily_git_summary.sh "$DATE"
```
If still missing after generation → no commits for this date. Session/meeting content may
still warrant a log — continue.

### 2c. Apply xpquest-daily-log skill logic

Execute the full logic from the `xpquest-daily-log` skill for this DATE:
- Step 3: Fetch issue context (gh issue view for each #NN in summary)
- Step 4: Read Claude sessions for this date (find by mtime)
- Step 5: Read meeting notes
- Step 6: Read time log
- Step 7: Classify SR&ED (WP1–WP6)
- Step 8: Write daily_log (or overwrite bash draft)
- Step 9: Write sred_daily_log if SR&ED content found

Do not re-read or re-run steps already covered by the github_summary.

### 2d. Record result for report

Track: `date | daily_log status | sred_log status`
Where status is one of: `created` | `enriched` | `skipped` | `exists`

---

## Step 3: Final report

After all dates:

```
Backfill complete: <FROM> to <TO>

| Date       | daily_log    | sred_log     | Sessions | Commits |
|------------|--------------|--------------|----------|---------|
| YYYY-MM-DD | created      | created      | 2        | 4 (1 SR&ED) |
| YYYY-MM-DD | enriched     | skipped      | 1        | 2       |
| YYYY-MM-DD | exists       | exists       | —        | —       |
| YYYY-MM-DD | skipped      | skipped      | 0        | 0       |
```

Statuses:
- `created` — new file written
- `enriched` — replaced a bash-only draft with session-enriched version
- `exists` — already complete, not touched
- `skipped` — no content found for this date
