# XP Quest — Org-Level Tooling (xpq-org)

This repo is the GitHub org-level `.github` repository for XP-Quest. It holds three things:

1. **GitHub templates** — issue templates, PR template, and Copilot instructions that apply
   org-wide to every XP-Quest repo.
2. **Operational scripts** — the daily-log pipeline, time tracker, and git hooks that enforce
   the issue-driven development workflow.
3. **Claude Code skills** — agent skill definitions for enriching daily logs with session context.

---

## From idea to development: the full workflow

Every piece of work — engineering, SR&ED research, or administration — follows the same path.
The steps below describe what happens and which tools enforce each transition.

### 1. Capture the idea as a GitHub issue

Before any code is written, an issue must exist.

```bash
gh issue create --repo XP-Quest/<repo>
```

Use the right template:

| Template | When to use |
| --- | --- |
| **SR&ED Research Issue** | Investigating a technical uncertainty (WP1–WP6). Fill in Hypothesis, Uncertainty Statement, and Experimental Plan before starting. |
| **Experiment Log Entry** | One experimental run under a parent research issue. |
| **Engineering Task** | Routine work — features, refactors, fixes, infra. Includes a SR&ED screening checkbox. |

The issue number (e.g. `42`) is the key that links everything that follows.

### 2. Create a branch named for the issue

```bash
git checkout -b 42-chunker-baseline
```

Branch naming convention: `N-slug` where N is the issue number.

**What fires automatically:** The Claude Code PostToolUse hook detects the branch creation and prints:

```text
⏱  Start time tracking for issue #42:
   xpq-org/scripts/xpq-time.sh start 42
```

Run that command to begin the timer. It auto-detects the WP label from the issue.

### 3. Do the work — guardrails are active

Claude Code's PreToolUse hook (`xpq-branch-guard.sh`) validates the active branch before every
file write or edit. If you are on `main` or any branch without a leading issue number, the Write
and Edit tools are blocked with a clear message before any change is made.

The commit-msg hook enforces the commit subject format at every `git commit`:

- On branch `42-chunker-baseline`, commits are auto-prefixed `#42:` (plus a space) if not already present.
- A commit subject referencing a different issue number is rejected.
- A commit with no issue prefix on a non-issue branch is rejected.

This means no commit can land without being traceable to a GitHub issue.

### 4. Open a pull request

```bash
gh pr create
```

**What fires automatically:** The Claude Code PostToolUse hook detects the PR creation and prints:

```text
⏱  Stop time tracking before merging:
   xpq-org/scripts/xpq-time.sh stop
```

Run that command. Hours are written to `journal/.time-log.csv`. Commit that file — the git
timestamp is contemporaneous evidence of when the work was performed.

### 5. The daily log is generated

At the end of each day (or as a backfill), two steps produce the development record:

**Step 1 — run in a terminal** to extract commits from all repos, grouped by issue:

```bash
bash xpq-org/scripts/daily_git_summary.sh 2026-05-05
```

**Step 2 — run inside a Claude Code session** (not the terminal) using the `/xpquest-daily-log`
slash command, which is a Claude Code skill, not a shell script:

```text
/xpquest-daily-log 2026-05-05
/xpquest-daily-log --from 2026-04-21 --to 2026-05-05
```

Step 1 produces `github_summary-DATE.md` (structured commit data).
Step 2 reads the summary, fetches issue body context via `gh issue view`, reads today's
Claude Code session history, and writes:

- `daily_log-DATE.md` — complete development record (all work: engineering + admin + SR&ED)
- `sred_daily_log-DATE.md` — SR&ED-only extraction for CRA auditing (written only when SR&ED work is found)

Both files land in `xpq-project/Daily Logs/`.

The SR&ED log is not a separate workflow — it is extracted from the same evidence that
documents all development. A clean issue trail makes the extraction automatic.

---

## Repository layout

```text
xpq-org/
├── .github/
│   ├── ISSUE_TEMPLATE/
│   │   ├── sred-research.yml       SR&ED research issue (long-lived investigation)
│   │   ├── experiment-log.yml      One experimental run; references a parent issue
│   │   ├── engineering-task.yml    Routine work; includes SR&ED screening checkbox
│   │   └── config.yml              Disables blank issues
│   ├── pull_request_template.md    PR template with SR&ED linkage field
│   └── copilot-instructions.md     Org-wide Copilot context (workflow, WPs, tech stack)
│
├── scripts/
│   ├── daily_git_summary.sh        Commit summary for one date → github_summary-DATE.md
│   ├── historical_git_summary.sh   Batch runner with checkpoint; backfills a date range
│   ├── xpq-time.sh                 Time tracker: start/stop/status → journal/.time-log.csv
│   ├── xpq-time-prompt.sh          PostToolUse hook: prompts time start/stop at key events
│   ├── xpq-branch-guard.sh         PreToolUse hook: blocks edits when not on issue branch
│   ├── reconcile_commit.sh         Attach an untracked commit to an issue retroactively
│   ├── install-hooks.sh            Install the commit-msg hook into any git repo
│   ├── hooks/
│   │   └── commit-msg              Enforces #N: subject format; auto-prepends when possible
│   └── tests/
│       ├── run_tests.sh            Run all bats test suites
│       ├── commit-msg.bats
│       ├── daily_git_summary.bats
│       ├── historical_git_summary.bats
│       ├── install-hooks.bats
│       ├── reconcile_commit.bats
│       └── helpers/                Mock gh binary and other test utilities
│
├── skills/
│   ├── xpquest-daily-log.md        Claude Code skill: /xpquest-daily-log [DATE]
│   └── xpquest-backfill-logs.md    Claude Code skill: /xpquest-backfill-logs [--from] [--to]
│
├── journal/                        Runtime data — committed to git for timestamps
│   ├── .reconciled                 SHAs suppressed from (untracked) in daily summaries
│   ├── .time-log.csv               Tab-delimited: date, issue, repo, wp, start, stop, hours
│   ├── .time-active                In-progress timer state (deleted on stop)
│   └── .daily-log-checkpoint       Last date processed by historical_git_summary.sh
│
├── SR_ED_CONVENTIONS.md            Full conventions: issue types, labels, commit rules, SR&ED guidance
└── README.md                       This file
```

---

## Script reference

### `daily_git_summary.sh [DATE]`

Scans all git repos under `~/xpquest/`, collects commits for DATE (default: today), and
groups them by GitHub issue using a three-layer attribution scheme:

1. **Layer 1** — commit subject starts with `#N:` → attributed directly to issue N
2. **Layer 2** — no prefix but branch is named `N-slug` → attributed to issue N via branch name
3. **Layer 3** — no attribution possible → lands in `(untracked)` section with reconcile instructions

Writes `github_summary-DATE.md` and a draft `daily_log-DATE.md` to `xpq-project/Daily Logs/`.
The draft daily log is replaced by the enriched version when `/xpquest-daily-log` runs.

Env overrides: `SEARCH_ROOT`, `OUTPUT_DIR`, `RECONCILED_FILE`, `TIME_LOG`.

### `historical_git_summary.sh [--from DATE] [--to DATE] [--checkpoint FILE]`

Runs `daily_git_summary.sh` for each date in a range. Without `--from`, resumes from the
checkpoint file (`journal/.daily-log-checkpoint`). Without `--to`, defaults to yesterday.
On completion, updates the checkpoint to today so the next run picks up from here.

First run (no checkpoint exists yet):

```bash
bash xpq-org/scripts/historical_git_summary.sh --from 2026-04-01
```

Subsequent runs (daily, scheduled, or manual):

```bash
bash xpq-org/scripts/historical_git_summary.sh
```

### `xpq-time.sh start|stop|status`

Minimal time tracker for all development work. Writes to `journal/.time-log.csv`.

```bash
xpq-org/scripts/xpq-time.sh start 42                      # begin timing issue #42
xpq-org/scripts/xpq-time.sh start 42 --repo XP-Quest/xpq-api
xpq-org/scripts/xpq-time.sh stop                          # record elapsed time
xpq-org/scripts/xpq-time.sh status                        # show running timer
```

Auto-detects the WP label (wp1–wp6) from the issue via `gh issue view`. Commit
`journal/.time-log.csv` regularly — git timestamps are the contemporaneous evidence.

### `reconcile_commit.sh <sha> <issue>`

Used when a commit lands in the `(untracked)` section of a daily summary. Posts a comment
to the issue on GitHub linking the commit, then appends the SHA to `journal/.reconciled`
so future summaries suppress it from the untracked section.

```bash
cd ~/xpquest/xpq-api
xpq-org/scripts/reconcile_commit.sh ff53fb4 12
```

Run from inside the repo that holds the commit. Use `--dry-run` to preview.

### `install-hooks.sh [repo-path]`

Installs the commit-msg hook into a git repo by symlinking. Run once per repo.
Also sets `core.commentChar=;` so `#N:` subjects survive git's cleanup pass.

```bash
# Install into current directory
bash xpq-org/scripts/install-hooks.sh

# Install into a specific repo
bash xpq-org/scripts/install-hooks.sh ~/xpquest/xpq-api
```

### Hook scripts (invoked by Claude Code — not run directly)

| Script | Event | Trigger | Action |
| --- | --- | --- | --- |
| `xpq-branch-guard.sh` | PreToolUse | Any Write or Edit | Blocks if active branch is not `N-slug` |
| `xpq-time-prompt.sh` | PostToolUse | `git checkout -b`, `git switch -c`, `gh pr create` | Prints time tracking reminder |

Both are registered in `~/.claude/settings.json` and apply to all repos under `~/xpquest/`.

---

## Claude Code skills

Skills are defined in `skills/` and wired into `~/.claude/skills/` for discovery.
Each skill requires a subdirectory named after the command containing a `SKILL.md` file:

```text
~/.claude/skills/
└── xpquest-daily-log/
    └── SKILL.md  →  ~/xpquest/xpq-org/skills/xpquest-daily-log.md  (symlink)
```

To set up after cloning:

```bash
mkdir -p ~/.claude/skills/xpquest-daily-log ~/.claude/skills/xpquest-backfill-logs
ln -s ~/xpquest/xpq-org/skills/xpquest-daily-log.md    ~/.claude/skills/xpquest-daily-log/SKILL.md
ln -s ~/xpquest/xpq-org/skills/xpquest-backfill-logs.md ~/.claude/skills/xpquest-backfill-logs/SKILL.md
```

Invoke from within a Claude Code session:

| Command | What it does |
| --- | --- |
| `/xpquest-daily-log [DATE]` | One date (default: yesterday). Always writes/overwrites. |
| `/xpquest-daily-log --from DATE [--to DATE]` | Date range. Always writes/overwrites. |
| `/xpquest-backfill-logs [--from DATE] [--to DATE]` | Date range, skips already-complete logs, resumes from checkpoint. |

Both skills read the bash-generated `github_summary` as structured input, augment it with
`gh issue view` body content (the PM/architecture "why"), read Claude Code session JSONL
files for narrative context, and write the enriched output.

---

## Setting up a new repo

When a new XP-Quest repo is created, run:

```bash
bash ~/xpquest/xpq-org/scripts/install-hooks.sh ~/xpquest/<new-repo>
```

The GitHub templates (issue templates, PR template, Copilot instructions) apply automatically
via the org-level `.github` repo — no per-repo setup needed.

---

## GitHub org wiring

The remote for this repo is `XP-Quest/.github`. GitHub requires exactly that name to treat
it as the org-level community health repo. The local directory is named `xpq-org` to avoid
a hidden folder name.

```bash
gh repo clone XP-Quest/.github ~/xpquest/xpq-org
```

Templates and the Copilot instructions file propagate automatically to all other XP-Quest
repos that do not define their own `.github/ISSUE_TEMPLATE/`. Per-repo overrides are
possible by adding a `.github/ISSUE_TEMPLATE/` folder in that repo.

---

## Journal files

`journal/` is committed to git. The files are small and their git commit timestamps provide
independent verification of when work was recorded — important for CRA contemporaneous
documentation.

| File | Purpose |
| --- | --- |
| `.reconciled` | One SHA per line; suppressed from `(untracked)` in daily summaries |
| `.time-log.csv` | Tab-delimited time entries. Header: `date, issue, repo, wp, start, stop, hours` |
| `.time-active` | State file while a timer is running; deleted by `xpq-time.sh stop` |
| `.daily-log-checkpoint` | Single date line; read by `historical_git_summary.sh` as next `--from` |

Commit `.time-log.csv` after each `xpq-time.sh stop`. Commit `.reconciled` after each
`reconcile_commit.sh` run.
