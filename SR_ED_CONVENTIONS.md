# XP Quest SR&ED Tracking Conventions

This document describes how XP Quest tracks technological uncertainty investigations across GitHub for the purpose of a Canadian SR&ED claim (federal) stacked with the Ontario Innovation Tax Credit (OITC).

It is written for a solo founder/developer who will also be the claim preparer.

---

## The six work packages (technological uncertainties)

| ID  | Work Package                                                      |
|-----|-------------------------------------------------------------------|
| WP1 | Semantic Chunking Strategy for Professional Documents             |
| WP2 | Relevance Gate Threshold Calibration                              |
| WP3 | Ambiguity Detection Heuristics                                    |
| WP4 | Conversational Augmentation Pipeline                              |
| WP5 | Dual-Score Job Description Correlation Engine                     |
| WP6 | Multi-Tenant Quota Enforcement with Cost Attribution              |

Every SR&ED research issue must be tagged to one of these (or "Cross-cutting").

## Issue types

**SR&ED Research Issue** — one per investigation. Lives from hypothesis through resolution. Long-lived. Carries the full audit trail (hypothesis, prior art, uncertainty statement, experiments, evidence, outcome).

**Experiment Log Entry** — short, cheap, one-per-run. References a parent research issue. Captures setup, result, next step. File as many as needed; these are the contemporaneous record of systematic investigation.

**Engineering Task** — everything else. Explicitly non-SR&ED. Carries an "Area" field and a screening checkbox so the distinction is visible.

## Labels

- `sred` — umbrella label for all SR&ED work. Apply to every SR&ED Research Issue and every Experiment Log Entry. The distinction between a research investigation and an experiment log entry is carried by the issue template (not a separate label), so `sred` alone is sufficient to filter all SR&ED activity in one query.
- `engineering` — non-SR&ED engineering work.
- `wp1` … `wp6`, `cross-cutting` — secondary label matching the Uncertainty field, for filtering by work package.

## Issue-driven commit workflow

Every code change is anchored to a GitHub issue. The issue is the persistent *why*; the commit is a checkpoint *what*; the daily log derived by `scripts/daily_git_summary.sh` connects the two for SR&ED evidence.

### Rules

1. **Every change has a GitHub issue.** Before making any change — requested by Robin or proposed by Claude — confirm a tracking issue exists in the relevant repo. If none exists, create one using the appropriate template (`sred-research`, `experiment-log`, or `engineering-task`). No issue, no commit.

2. **Branch names embed the issue number.** Format: `<issue>-<short-slug>`, lowercase and hyphenated. Examples: `42-semantic-chunker-baseline`, `58-oidc-ingress-filter`. This makes the issue reference recoverable from the branch and is the precondition for Rule 3.

3. **Commit subject format: `#<issue>: <summary>`.** `<issue>` matches the issue number in the branch; `<summary>` is one short line (≤72 chars). The leading `#NNN:` is what `daily_git_summary.sh` parses. The `commit-msg` hook in `scripts/hooks/commit-msg` enforces this — install it once per repo via `scripts/install-hooks.sh`.

4. **Each commit gets a verbose comment on the issue.** The commit subject is the headline; the issue comment is the story. Months from now, the daily-log entry plus the issue thread should be enough to reconstruct what changed and why without re-reading the diff. Cover: what was changed, why this approach, what was ruled out, what's next. The commit subject is a *summary* of this comment, never a duplicate of it.

5. **Multiple commits per issue stay ungrouped in the daily log.** The daily log emits one bullet per commit, even if several share an issue. The progression of commits *is* the contemporaneous record — collapsing them would erase iteration evidence (which matters for WP1–WP6 SR&ED claims). Prefer many small commits over large ones during investigation phases.

6. **PRs reference the parent issue in the SR&ED Linkage section** of the existing PR template. Contribution type field per the template.

### Worked example

Robin: *"Pick a chunking strategy for the résumé corpus and start with a fixed-size baseline."*

1. Search `XP-Quest/xpq-api` issues. None covers this.
2. File an SR&ED Research Issue, work package WP1. GitHub assigns **#42**: *"Implement semantic chunking baseline for résumé documents."*
3. Create branch `42-semantic-chunker-baseline` off `dev` (xpq-api is a deployable repo; feature branches come off the integration branch — see *Two-branch promotion* below).
4. Implement a `FixedSizeChunker` (512 tokens, 64 overlap).
5. Post comment to issue #42:
   > **Commit a3f8c1d** — Added a `FixedSizeChunker` at 512/64. 512 chosen to match the embedding model's context window without truncation. The 64-token overlap is a heuristic from the Anthropic RAG cookbook example, not yet calibrated — calibration belongs to a later experiment. Token-count metrics deliberately split into a separate commit so the chunker can be reviewed in isolation. Next: add metrics so we can compare strategies empirically (WP1 has no calibration without them).
6. Commit subject: `#42: add FixedSizeChunker baseline at 512/64`
7. Continue on the same branch — add metrics, post a second verbose comment, commit `#42: add token-count metrics to chunker output`.
8. Open a PR targeting `dev`; PR body's SR&ED Linkage section points to issue #42.

The next morning, `daily_git_summary.sh` produces:

```markdown
## xpq-api

- #42: Implement semantic chunking baseline for résumé documents
  a3f8c1d: add FixedSizeChunker baseline at 512/64
- #42: Implement semantic chunking baseline for résumé documents
  7b2e9f4: add token-count metrics to chunker output
```

Six months later at claim prep, those bullets link to issue #42's full comment thread — hypothesis, iteration, outcome — the contemporaneous evidence CRA wants for a solo claim.

### How the parser stays accurate (three layers)

**Layer 1 — Prevention.** The `commit-msg` hook rejects (or auto-prepends to) commits whose subject lacks `#NNN:`, where `NNN` is derived from the branch name. Installed via `scripts/install-hooks.sh`.

**Layer 2 — Mechanical recovery.** If a commit subject still lacks `#NNN:` (e.g., committed in a repo where the hook isn't installed), the parser inspects branches containing the commit via `git branch --all --contains` and looks for a branch name matching `^<digits>-`. When found, the issue is recovered silently — no GitHub write needed.

**Layer 3 — Human-judged attribution.** Commits that survive Layers 1 and 2 land in a `## (untracked)` section of the daily log. These are the residual cases requiring judgment. The commit is still recorded in that day's log — it just isn't linked to an issue — so the worst case is an unattributed (not lost) commit. Because the daily summary is date-scoped, an untracked commit surfaces only in its own day's log and does not recur on later runs.

### Layer 3 procedure (the manual judgment piece)

When `daily_git_summary.sh` emits a `## (untracked)` section, work through each commit:

1. **Read the diff** (`git show <sha>` in the relevant repo).
2. **Decide:**
   - *Attach to existing issue* if the diff clearly fits the scope of an open or recently-closed issue.
   - *File a new retroactive issue* if no existing issue fits. Use the appropriate template (`engineering-task` or `sred-research`); apply the `retroactive` label so retroactive filings are countable. Filing the issue retroactively is itself useful signal at claim time — it shows where process slipped.
   - *Never* attach by superficial keyword overlap. For SR&ED, attaching to the wrong WP issue is worse than leaving the commit orphaned, because it pollutes evidence.
3. **Attribute it.** If the commit has not been pushed, amend its subject to the `#NNN:` form. Otherwise, post a comment on the chosen issue linking the SHA, with a description as complete as if it had been written at commit time (Rule 4 standard). The audit trail then lives in the issue thread.

## PR and issue lifecycle

The commit conventions above govern *what lands on a branch*. This section governs *how branches become releases* and *when issues close*. It applies to every `xpq-*` repo, with one documented exception (the `#4`-class trivial fixes, below).

### Two-branch promotion (deployable repos)

`xpq-web` and `xpq-api` deploy from two long-lived branches:

- **`dev`** — staging. Feature branches merge here first.
- **`main`** — production (the repo's *default* branch). Only `dev` promotes here.

`xpq-org` and `xpq-infra` have no staging surface, so they are single-track: feature branch → PR → `main`. Where this section says "off `dev`", read it as "off the repo's integration branch" — `dev` for the deployable repos, `main` for the tooling/docs repos.

### Gates (convention over configuration)

XP Quest is on the free GitHub plan: no server-side branch protection, no required reviews, no CODEOWNERS. The gates below are **conventions the solo developer keeps by habit**, not rules the platform enforces. They are written so that following them produces a clean, defensible history without any paid tooling.

- **feature → `dev`:** open a PR; **self-managed** — the author merges without a review gate. The point of this merge is to get the change deployed onto the Azure dev environment (see *Deployment lifecycle* below) while the issue is still in progress. The PR body carries the issue keyword per the close-on-merge rule below.
- **`dev` → `main`:** open a PR; **this is the acceptance gate and it requires Robin's review.** Production is downstream of this merge. The promotion PR is also where issues close (next rule) and what drives the staging lifecycle (below).

Never open a PR from a feature branch straight to `main`. The one exception is a prod-only CI/infra change that can't be validated on `dev` (e.g. the production deploy workflow or Azure resource config): branch from `main` and PR to `main` directly. Claude must never merge a PR autonomously; Robin merges (self-managed means *Robin* merges his own dev-bound PRs without ceremony, not that the agent does).

### Deployment lifecycle (Azure environments)

The branch model above drives three environments. GitHub Actions workflows in each deployable repo implement this contract; the conventions here are authoritative when the two disagree.

| Trigger | Action | Environment |
| --- | --- | --- |
| Merge to `dev` | Deploy continuously | **dev** — always running, tracks `dev` while issues are in progress |
| **Open** a `dev` → `main` promotion PR | Provision + deploy an **ephemeral staging resource group** | **staging** — exists only while the promotion PR is open |
| **Merge** the promotion PR to `main` | **Tear down the staging resource group** | staging removed; its cost dies with it |
| Manual trigger (`workflow_dispatch`) | Deploy `main` to production | **prod** — human-initiated in early phases; automated promotion is a future introduction once gates mature |

- The promotion PR is the **system-test window**: for an epic, opening it is the moment the integrated MVP becomes testable as a whole on staging. Validation that needs only the dev environment happens earlier, continuously.
- Merging to `main` does **not** deploy production. Prod deploys are deliberate, manual events against `main`'s tip — at least until automated deployment is introduced.
- If staging testing fails, push fixes to `dev` (via feature branches as usual); the open promotion PR picks them up and staging redeploys. Closing a promotion PR without merging must also tear down staging.

### When issues close (the close-on-merge rule)

GitHub's `Closes #NN` / `Fixes #NN` keyword **only auto-closes when the PR merges into the repository's *default* branch** (`main`). A PR that merges into `dev` carrying `Closes #NN` does **not** close the issue — GitHub silently holds the keyword.

That mechanic drives the rule:

1. **Put `Closes #NN` in the `dev` → `main` promotion PR**, never in the feature → `dev` PR. Work is "done" when it reaches production — which is exactly when GitHub will honour the keyword. A promotion PR that carries several features closes them all — repeat the keyword per issue (GitHub only honours the first one otherwise): `Closes #41, closes #42, closes #43`.
2. **Feature → `dev` PRs may carry the keyword — it links, it cannot close.** Because the keyword only fires on default-branch merges, `Closes #NN` in a dev-bound PR is inert for closing — but it is the only way to get the PR into the issue's **Development** section (and therefore the project board's linked-PR indicator). One catch: GitHub registers the link only while the PR's base **is** the default branch. So either create the PR against `main` with the keyword and immediately retarget to `dev`, or flip an existing PR's base to `main` and back (`gh api -X PATCH .../pulls/N -f base=main`, verify, then `-f base=dev`) — the link survives retargeting. State in the PR body that closure happens at promotion.

### Branch hygiene

- **Enable "Automatically delete head branches"** in each repo's settings. Merged feature branches are then removed without manual cleanup.
- **Re-create `dev` from `main` after each promotion.** Auto-delete fires on merge of any PR whose *head* is the branch — and `dev` is the head of the promotion PR. Resetting `dev` to `main` right after promoting keeps the two from drifting and keeps `dev` a clean fast-forward base for the next cycle:

  ```bash
  git switch main && git pull
  git switch -C dev && git push --force-with-lease origin dev
  ```

- **No stale feature branches.** Once a branch is merged (and auto-deleted), don't resurrect it; branch fresh from the integration branch for the next issue.

### Epics: many issues, one integration branch

Most work is **one issue : one branch**. Keep it that way — it is the simplest mapping, and it makes the `commit-msg` hook's "`#<issue>` must equal the branch number" check exactly right.

Some work is larger than a single issue but ships as one MVP — observability (UI instrumentation + collector infra + dashboards) is the canonical example. For that, use a nested **integration branch**:

```
dev
└── <E>-observability            epic / integration branch, off dev
    ├── <a>-spa-telemetry        off <E>-…
    ├── <b>-collector-infra      off <E>-…
    └── <c>-metrics-dashboard    off <E>-…
```

- **Every branch is still 1:1 with an issue** — the epic with its tracking issue `#E`, each sub-branch with its sub-issue. Commits on `<a>-spa-telemetry` are `#a:`, and the `commit-msg` hook is satisfied with **no change**. That is the whole reason for this shape: it gives you many issues across one body of work *without* relaxing the commit guard.
- **Sub-PRs target the epic branch**, not `dev`. Check the base dropdown every time — a sub-PR accidentally opened against `dev` pushes a half-finished slice to staging.
- **Integrate from `dev` frequently.** The epic branch is long-lived, so it drifts from `dev` as other work lands. Merge `dev` → epic branch on a regular cadence (and cascade into the open sub-branches), so the final promotion is a small reconciliation instead of a large one. Integrate early, integrate often — do not let an epic branch sit for weeks.
- **Merge into the epic branch; never rebase it.** Rebasing the integration branch orphans the sub-branches based on it.
- **Manually close each sub-issue when its sub-PR merges into the epic branch.** Because `Closes` only fires on `main` (above), sub-PRs into the epic branch will *not* auto-close their issues. Closing them by hand at integration is what keeps the epic's sub-issue progress bar live — and that bar is your "is the MVP ready?" signal. The closure means "this slice is code-complete and integrated"; it ships when the epic ships.
- **The epic issue `#E` closes at production.** The `dev` → `main` promotion PR carries `Closes #E`. So sub-issues close at *integration*; the epic closes at *prod*. This is a deliberate, narrow exception to the close-on-merge rule above — the only place an issue closes before reaching `main`.
- **The epic branch is deploy-silent.** Pushing the epic branch deploys nothing, and sub-PRs into it get no preview environment. The integrated whole hits the **dev environment** when the epic merges to `dev`, and gets its **staging** system-test window when the promotion PR opens (see *Deployment lifecycle*).
- **SR&ED work stays 1:1.** The epic model is a non-SR&ED convenience. A SR&ED research issue is its own branch with its own granular commit trail (its Experiment Log *issues* are children, not branches) — don't fold SR&ED investigations onto an epic branch, or you blur the per-issue evidence the claim depends on.

### The `#4`-class exception

Trivial fixes (typos, formatting, doc cleanups) tracked under a repo's standing "Trivial fixes" issue are exempt from the promotion ceremony: a single branch, a direct PR, no epic, no sub-issue bookkeeping. Reserve this for genuinely trivial, non-feature changes only.

## Time tracking

CRA wants hours attributable to specific SR&ED work packages, not bulk "I coded today."

Recommended minimum:
- End-of-day markdown journal entry in the `.github` repo under `journal/YYYY/MM/DD.md`.
- Two sections: "SR&ED time" (with `WP{n}` tags and issue references) and "Non-SR&ED time."
- One sentence per entry is enough. Contemporaneous > polished.

If using a tool (Toggl, Harvest, etc.), put the issue number in the description so time entries map back to research issues cleanly at claim time.

## Board structure

Two GitHub Projects at the org level:

1. **R&D / AI Engine** — all SR&ED research and experiment issues. Custom fields: Uncertainty (WP1–WP6), Phase.
2. **Product & Platform** — non-SR&ED engineering. Custom fields: Area, Priority.

## Before filing a research issue, ask yourself

1. Is there a real technological uncertainty here that a skilled practitioner couldn't resolve with existing knowledge and routine effort? If no, file it as an Engineering Task instead.
2. Can I state a hypothesis that could be falsified? If no, keep thinking before filing.
3. Have I reviewed prior art and can I articulate why it's insufficient? If no, do that first — it's the first field in the template for a reason.

If any of those is "no," you probably don't have a SR&ED investigation yet — just engineering work.

## At claim time

The narrative for each work package writes itself from the research issues under that uncertainty:

- Hypothesis → "We hypothesized that…"
- Prior art → "Existing approaches were inadequate because…"
- Experiments (from child Experiment Log entries) → "We systematically investigated by…"
- Evidence → "Supporting artifacts include…"
- Outcome → "We concluded that…"

If those fields are populated contemporaneously, the claim writes itself. If they're not, you're reconstructing 14 months later from git log and memory — which is where most solo-founder SR&ED claims go wrong.

## Not legal/tax advice

This is a working convention, not a legal opinion on SR&ED eligibility. Final eligibility decisions belong to your accountant and, ultimately, to CRA. Document thoroughly, label conservatively, and escalate ambiguous cases to your advisor before claim submission.
