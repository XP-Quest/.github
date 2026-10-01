# XP Quest — Org-Level Tooling (xpq-org)

This repo is the GitHub org-level `.github` repository for XP-Quest. It holds three things:

1. **GitHub templates** — issue templates, PR template, and Copilot instructions that apply
   org-wide to every XP-Quest repo.
2. **Operational scripts** — the daily-log pipeline and git hooks that enforce the
   issue-driven development workflow.
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

Track time against the issue in the **XP Quest Time Tracker** (the desktop widget from
`rdcoe/timetracking`), tagging the entry to the matching workstream code — `xpq-eng`,
`xpq-sred`, or `xpq-techops`. The widget's Daily Summary is what the daily-log pipeline reads
later (see step 5); there is no shell command to run.

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

Stop the timer for this issue in the **XP Quest Time Tracker** widget before merging. Tracked
hours live in the widget's own store and surface in its Daily Summary — there is no file to
commit.

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

Both files land in `xpq-project/Daily-Logs/`.

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
│   ├── workflows/
│   │   ├── pr-lifecycle*.yml       Closing-keyword guard (reusable + xpq-org caller)
│   │   └── branch-cleanup*.yml     Delete merged feature branches on merge to main (reusable + caller)
│   ├── pull_request_template.md    PR template with SR&ED linkage field
│   └── copilot-instructions.md     Org-wide Copilot context (workflow, WPs, tech stack)
│
├── scripts/
│   ├── daily_git_summary.sh        Commit summary for one date → github_summary-DATE.md
│   ├── historical_git_summary.sh   Batch runner with checkpoint; backfills a date range
│   ├── branch-cleanup.sh           Delete branches whose work reached main (run by the workflow)
│   ├── xpq-org-main-update.sh      Unlock → fast-forward → relock the read-only .xpq-org-main clone
│   ├── prune-local-branches.sh     Delete local branches already on origin/dev or origin/main
│   ├── xpq-branch-guard.sh         PreToolUse hook: blocks edits when not on issue branch
│   ├── install-hooks.sh            Install the commit-msg hook into any git repo
│   ├── hooks/
│   │   └── commit-msg              Enforces #N: subject format; auto-prepends when possible
│   └── tests/
│       ├── run_tests.sh            Run all bats test suites
│       ├── branch-cleanup.bats
│       ├── commit-msg.bats
│       ├── daily_git_summary.bats
│       ├── historical_git_summary.bats
│       ├── install-hooks.bats
│       ├── xpq-org-main-update.bats
│       ├── prune-local-branches.bats
│       └── helpers/                Mock gh binary and other test utilities
│
├── skills/
│   └── xpquest-daily-log.md        Claude Code skill: /xpquest-daily-log [DATE]
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
3. **Layer 3** — no attribution possible → lands in `(untracked)` section for human review

A Layer 3 commit is still recorded in that day's log; it just isn't linked to an issue.
Attribute it by amending the commit subject or noting the SHA on the relevant issue.

Writes `github_summary-DATE.md` and a draft `daily_log-DATE.md` to `xpq-project/Daily-Logs/`.
The draft daily log is replaced by the enriched version when `/xpquest-daily-log` runs.

Env overrides: `SEARCH_ROOT`, `OUTPUT_DIR`, `MEETINGS_DIR`, `XPQUEST_SUMMARY_DIR` (with `$HOME/.xpquest` as a fallback).

### `historical_git_summary.sh [--from DATE] [--to DATE] [--checkpoint FILE]`

Runs `daily_git_summary.sh` for each date in a range. Without `--from`, resumes from the
checkpoint file (`~/.xpquest/.daily-log-checkpoint`). Without `--to`, defaults to yesterday.
On completion, updates the checkpoint to today so the next run picks up from here.

First run (no checkpoint exists yet):

```bash
bash xpq-org/scripts/historical_git_summary.sh --from 2026-04-01
```

Subsequent runs (daily, scheduled, or manual):

```bash
bash xpq-org/scripts/historical_git_summary.sh
```

### `prune-local-branches.sh [--dry-run] [--include-current] [--root DIR] [REPO ...]`

Deletes **local** branches whose work is already integrated, in every clone under `~/xpquest`
(hidden clones such as `.xpq-org-main` are skipped). `branch-cleanup.yml` handles the remote
side once work reaches `main`. This covers your clones, so `git branch` lists only work that
is still outstanding.

A branch is pruned when it was pushed under its own name and its tip is on `origin/dev` or
`origin/main`, so no commit can be lost. `N-trivial-fixes` branches are pruned too. It never
touches `main`, `dev`, unmerged or never-pushed branches, or a branch checked out in any worktree.
`--include-current` also prunes the checked-out branch if the worktree is clean: it switches to
the integration branch and fast-forwards it first.

```bash
bash xpq-org/scripts/prune-local-branches.sh --dry-run --include-current   # preview
bash xpq-org/scripts/prune-local-branches.sh --include-current
```

**Reopening a branch:** `git switch N-slug` recreates it from `origin/N-slug`. That works for
the permanent `N-trivial-fixes` branches and for any branch merged to `dev` but not yet
promoted. If the remote is gone (the branch reached `main`), branch fresh off `dev` instead.
When you reopen a trivial-fixes branch, merge `dev` into it first, since it lags behind.

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
| `xpq-pr-merge-guard.sh` | PreToolUse | `gh pr merge` | Hard-denies autonomous PR merges |

These are registered in `~/.claude/settings.json` and apply to all repos under `~/xpquest/`.

---

## Claude Code skills

Skills are defined in `skills/` and wired into `~/.claude/skills/` for discovery. They run
from `~/xpquest/.xpq-org-main` — a second clone of this repo that stays on `main` and is
never used for coding (#57). The skill symlink and the scripts it calls both point there, so
the code that produces the daily/SR&ED logs is always reviewed `main`, identical on every
machine, and unaffected by whatever branch the working `~/xpquest/xpq-org` clone has checked
out. The skill's preflight step fast-forwards the clone on every run — no manual pull needed.

The clone's working tree is **read-only** (files and directories; `.git/` excluded) so that
nothing can drift from `main` by accident (#65). `scripts/xpq-org-main-update.sh` is the only
update path: it unlocks, runs `git pull --ff-only`, and relocks, even if the pull fails. A
plain `git pull` in the clone fails by design.

```text
~/.claude/skills/
└── xpquest-daily-log/
    └── SKILL.md  →  ~/xpquest/.xpq-org-main/skills/xpquest-daily-log.md  (symlink)
```

To set up on each machine:

```bash
gh repo clone XP-Quest/.github ~/xpquest/.xpq-org-main
mkdir -p ~/.claude/skills/xpquest-daily-log
ln -sfn ~/xpquest/.xpq-org-main/skills/xpquest-daily-log.md ~/.claude/skills/xpquest-daily-log/SKILL.md
```

No separate lock step is needed: the skill's first run goes through the update script, which
leaves the clone locked. To lock straight away, run `bash ~/xpquest/.xpq-org-main/scripts/xpq-org-main-update.sh --lock`.

To update by hand, run `bash ~/xpquest/.xpq-org-main/scripts/xpq-org-main-update.sh`. This only
protects against accidents: `chmod -R u+w` undoes it, so don't.

Never edit, branch, or commit in `.xpq-org-main`. The lock prevents casual edits, and any local
change would block the fast-forward (the skill warns and runs the stale checkout). Do all work in `~/xpquest/xpq-org`.

Invoke from within a Claude Code session:

| Command | What it does |
| --- | --- |
| `/xpquest-daily-log [DATE]` | One date (default: yesterday). Always writes/overwrites. |
| `/xpquest-daily-log --from DATE [--to DATE]` | Date range. Always writes/overwrites. |

The skill reads the bash-generated `github_summary` as structured input, augments it with
`gh issue view` body content (the PM/architecture "why"), reads Claude Code session JSONL
files for narrative context, and writes the enriched output.

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

## Skill state (`~/.xpquest`)

The daily-log pipeline keeps its local, per-machine state in `~/.xpquest/`, **outside** any
git repo — so a branch switch or `git clean` can never delete it (which is exactly what
happened when this state lived in the repo's old `journal/` folder). This state is owned by
the skill and is independent of the XP Quest Time Tracker; the widget happens to use the same
directory but manages its own files there. The skill's only coupling to the tracker is a
read-only import of `daily-summary-<DATE>.json` *iff* present (see `daily_git_summary.sh`).
Override the location with `DAILY_LOG_CHECKPOINT` (or `--checkpoint FILE`).

| File | Purpose |
| --- | --- |
| `~/.xpquest/.daily-log-checkpoint` | Single date line; read by `historical_git_summary.sh` as next `--from` |
