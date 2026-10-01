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

## Referencing issues

GitHub resolves a bare `#NN` **against the repository you are writing in**. That makes a bare cross-repo reference worse than a dead link — it is a wrong live one. `#26` written in an xpq-api issue points at `xpq-api#26`, a real and unrelated issue, not the xpq-web issue that was meant. A partial `xpq-web#26`, with no owner, does not autolink at all.

- **Same repo:** `#NN`. Do not qualify a same-repo reference — `XP-Quest/xpq-api#69` inside xpq-api is noise.
- **Any other repo:** `XP-Quest/<repo>#NN` — e.g. `XP-Quest/xpq-web#8`, `XP-Quest/xpq-infra#12`.
- **This repo is `XP-Quest/.github`, not `xpq-org`.** `xpq-org` is only the local clone directory name (GitHub's org-level health repo must be named `.github`). `XP-Quest/xpq-org#4` points at nothing; write `XP-Quest/.github#4`.

Applies everywhere the reference is meant to be read as a link: issue bodies, PR titles and bodies, comments, and commit trailers. Use the same-repo or owner-qualified form above. Epic checklists depend on it in particular — *Epics: many issues, one atomic unit* relies on cross-repo items rendering and ticking across repos, and the owner-qualified form is what makes that work.

Two places the rule deliberately does **not** apply:

- **Commit subjects stay bare.** The `#NNN:` prefix is parsed by `daily_git_summary.sh` against the repo the commit lives in, and a commit is always about its own repo's issue. Rule 3's format is unchanged.
- **Closing keywords stay same-repo.** GitHub does support `Closes owner/repo#NN`, but the convention never needs it: each repo's own promotion PR closes that repo's issues (see *Epics* and *When issues close*). The `pr-lifecycle` guard enforces this shape — its regex requires `#` directly after the keyword, so an owner-qualified `Closes` would fail the check. If a cross-repo close is ever genuinely needed, widen the guard in the same change rather than working around it.

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

`xpq-web`, `xpq-api`, and `xpq-infra` each carry two long-lived branches, and releases are cut from `main` as tags:

- **`dev`**: integration, validated **one repo at a time** on the **local** stack (Kind + OIDC Dev Services, $0). Feature branches merge here first.
- **`main`**: the repo's *default* branch and the **system-test baseline**. With every `xpq-*` clone checked out on `main`, `dev-up.sh` runs the whole platform as it stands across repos. Only `dev` promotes here. Merging to `main` deploys nothing.
- **Release tags (`vX.Y.Z`) on `main`**: the **atomic deployable unit** and the only thing that reaches production (see *Deployment lifecycle*).

`xpq-org` is pure tooling/docs with no environment. It is single-track: feature branch → PR → `main`. Where this section says "off `dev`", read it as "off the repo's integration branch": `dev` for the deployable repos, `main` for `xpq-org`.

`xpq-infra` is deployable, but its "deploy" is indirect: its Bicep *defines* the staging and prod resource groups that releases build from. An `xpq-infra` promotion means "this Bicep is ready to be consumed by the next staging or prod build", not an independent cloud push.

### Gates (convention over configuration)

XP Quest is on the free GitHub plan: no server-side branch protection, no required reviews, no CODEOWNERS. The gates below are **conventions the solo developer keeps by habit**, not rules the platform enforces. They are written so that following them produces a clean, defensible history without any paid tooling.

- **feature → `dev`:** open a PR. This is **self-managed**: the author merges without a review gate. The merge integrates the change on `dev` so it can be validated on the **local** stack in that repo's scope. The PR body carries the issue keyword per the close-on-merge rule below.
- **`dev` → `main` (promotion):** open a PR. **This is the acceptance gate and it requires Robin's review.** Promote **whenever `dev` is green locally**. Promotions are meant to be frequent and small, and **promoting mid-epic is normal**. The promotion PR is where issues close (next rule). Its test plan includes a cross-repo system test from `main` on the local stack.
- **Release tag on `main`:** cut deliberately, when a standalone issue or an epic is complete (see *Deployment lifecycle*).

Never open a PR from a feature branch straight to `main`. The one exception is a prod-only CI/infra change that can't be validated on `dev` (e.g. the production deploy workflow or Azure resource config): branch from `main` and PR to `main` directly. Claude must never merge a PR autonomously; Robin merges (self-managed means *Robin* merges his own dev-bound PRs without ceremony, not that the agent does).

### Deployment lifecycle (Azure environments)

GitHub Actions workflows in each deployable repo implement this contract; the conventions here are authoritative when the two disagree.

**The atomic deployable unit is a release tag, cut when a *standalone issue* or an *epic* is complete.** Cloud is entered only at a tag, never on a `dev` or `main` merge. The epic exists to widen "atomic" from one issue to a coordinated, possibly cross-repo set (app + infra) that must move as one. Only one environment is always-on:

| Trigger | Action | Environment |
| --- | --- | --- |
| Merge to `dev` | Integrate; validate in the repo's own scope. **No Azure deploy.** | **local**: Kind + OIDC Dev Services, $0 |
| Merge a promotion PR to `main` | System-test across repos from `main`. **No Azure deploy.** | **local**: same stack, all clones on `main` |
| *(future)* Push a release-candidate tag `vX.Y.Z-rc.N` | Provision an **ephemeral staging resource group** from `xpq-infra` Bicep; deploy the tagged app + infra into it | **staging**: exists only until the release is cut or abandoned |
| Push a release tag `vX.Y.Z` (or manual `workflow_dispatch` at the tag) | Deploy the tag to production; tear down any staging for it | **prod**: human-initiated, since a person pushes the tag |

**Why mid-epic promotion is safe:** nothing downstream of `main` deploys on merge, so a half-integrated epic on `main` reaches no cloud environment. The cross-repo ordering hazard (an app change deployed before its Azure migration) is handled at the tag instead. An epic is not released until all of its sub-issues are on `main` in every repo, and staging, built **fresh from Bicep**, cannot drift from un-applied infra.

- **`main` must always be releasable.** A tag ships `main`'s tip, with no cherry-picking, so any unfinished epic slices sitting on `main` ship with the next release of *anything*. A mid-epic slice may be promoted only if it is **inert when released**: not yet wired into a route, menu or flow, or switched off by config. A slice that would break or expose half a feature belongs on the epic branch until the epic is complete (§Epics). Promotion is frequent; tagging is the deliberate act.
- **`dev` must be green before promotion.** It needs to work on the local stack, but it does not need to be "complete". There is **no promotion freeze**: promotions are small, and no environment is tied to an open promotion PR, so unrelated `dev` merges during review are harmless. If one lands, the PR simply carries it, and the test plan covers what was merged.
- **Staging is not built yet.** When it is, it hangs off release-candidate tags rather than promotion PRs, so frequent promotions create no resource groups. Abandoning a candidate (no release cut) must also tear its staging down.
- **Prod is deliberate.** `xpq-web` already deploys to SWA only on exact `vX.Y.Z` tag pushes (XP-Quest/xpq-web#31). `xpq-api` and `xpq-infra` follow the same contract once their deploy workflows exist.

### When issues close (the close-on-merge rule)

GitHub's `Closes #NN` / `Fixes #NN` keyword **only auto-closes when the PR merges into the repository's *default* branch** (`main`). A PR that merges into `dev` carrying `Closes #NN` does **not** close the issue — GitHub silently holds the keyword.

That mechanic drives the rule:

1. **Put `Closes #NN` in the `dev` → `main` promotion PR**, never in the feature → `dev` PR. An issue is "done" when it reaches `main`, meaning it has been system-tested and is releasable, which is exactly when GitHub will honour the keyword. Release is a separate, later event: it is tracked by the tag and, for epics, by closing the epic issue (§Epics). A promotion PR that carries several features closes them all — repeat the keyword per issue (GitHub only honours the first one otherwise): `Closes #41, closes #42, closes #43`.
2. **Feature → `dev` PRs may carry the keyword — it links, it cannot close.** Because the keyword only fires on default-branch merges, `Closes #NN` in a dev-bound PR is inert for closing — but it is the only way to get the PR into the issue's **Development** section (and therefore the project board's linked-PR indicator). One catch: GitHub registers the link only while the PR's base **is** the default branch. So either create the PR against `main` with the keyword and immediately retarget to `dev`, or flip an existing PR's base to `main` and back (`gh api -X PATCH .../pulls/N -f base=main`, verify, then `-f base=dev`) — the link survives retargeting. State in the PR body that closure happens at promotion.

### Branch hygiene

- **Leave "Automatically delete head branches" off.** It is one per-repo checkbox: it cannot exempt the permanent `N-trivial-fixes` branches, and it cannot filter by base branch. Branch protection, the only documented opt-out, is not available on the private repos' plan. Cleanup is done instead by each repo's `branch-cleanup.yml` caller, which runs the org-wide reusable workflow (`branch-cleanup-reusable.yml`, logic in `scripts/branch-cleanup.sh`).
- **A branch is deleted when its work reaches `main`, not when it merges to `dev`.** When a PR is merged into `main`, the workflow deletes the PR's own head branch (a feature → `main` PR: Track 2, or any xpq-org PR) and the head branch of every merged PR that rode a `dev` → `main` promotion. The second set is found by walking the promotion PR's commits to the PRs they belong to — exactly the work merged to `dev` since the last promotion. A feature branch therefore lives from creation until it is promoted.
- **It never deletes** `main`, `dev`, an `N-trivial-fixes` branch, a branch from a fork, a branch that is the head or the base of an open PR, or a branch whose tip has moved past the merged head (commits pushed after the merge). Each outcome is listed in the run summary; skips are normal, a failed delete fails the run.
- **Epic sub-branches are only found if the epic → `dev` PR is merged with a merge commit.** Squashing or rebasing it replaces the sub-PRs' commits, so the walk cannot see them; delete those branches by hand.
- **Replay or dry-run a cleanup:** in a repo's Actions tab run *branch-cleanup* with a merged PR number (it defaults to dry run), or locally `scripts/branch-cleanup.sh --repo OWNER/REPO --pr N --dry-run`.
- **Re-create `dev` from `main` after each promotion.** The promotion merge commit lands on `main` but not on `dev`, so the two drift apart. Resetting `dev` to `main` right after promoting keeps `dev` a clean fast-forward base for the next cycle. With no promotion freeze, first check that nothing landed on `dev` after the promotion merged: `git log origin/main..origin/dev` must be empty. If it isn't, merge `main` into `dev` instead of resetting:

  ```bash
  git switch main && git pull
  git switch -C dev && git push --force-with-lease origin dev
  ```

- **No stale feature branches.** Once a branch is merged and cleaned up, don't resurrect it; branch fresh from the integration branch for the next issue.

### Epics: many issues, one atomic unit

Most work is **one issue : one branch**. Keep it that way — it is the simplest mapping, and it makes the `commit-msg` hook's "`#<issue>` must equal the branch number" check exactly right.

An **epic** is the wrapper for **any multi-story deliverable** — any deliverable whose stories must land together for the system to stay stable. Epic scope is defined by *atomicity, not size*: two stories that would break the system if deployed apart are an epic; a ten-story deliverable whose stories are each independently shippable is not (those are just ten issues). The trigger is "do these have to move as one to maintain stability?" — most often because they coordinate changes across repos (app + infra). The epic's tracking issue `#E` is the orchestrator. Its slices may reach `main` as they finish, provided each is inert when released (see *Deployment lifecycle*), but **no release tag ships the epic until *every* sub-issue is complete**. This is the whole reason the deployment lifecycle can gate on completed units without per-issue dependency bookkeeping: the epic *is* the dependency boundary.

Two shapes, by whether the work lives in one repo or several.

#### Single-repo epic — nested integration branch

A multi-story deliverable inside a single repo whose slices **cannot sit inert on `main`** uses a nested **integration branch**. Observability is the canonical example: UI instrumentation, collector infra and dashboards must ship together to be coherent. If each slice *can* sit inert, skip the epic branch: sub-issues follow the ordinary feature → `dev` → `main` flow and the epic issue just tracks them.

```
dev
└── <E>-observability            epic / integration branch, off dev
    ├── <a>-spa-telemetry        off <E>-…
    ├── <b>-collector-infra      off <E>-…
    └── <c>-metrics-dashboard    off <E>-…
```

- **Every branch is still 1:1 with an issue** — the epic with its tracking issue `#E`, each sub-branch with its sub-issue. Commits on `<a>-spa-telemetry` are `#a:`, and the `commit-msg` hook is satisfied with **no change**. That is the whole reason for this shape: it gives you many issues across one body of work *without* relaxing the commit guard.
- **Sub-PRs target the epic branch**, not `dev`. Check the base dropdown every time — a sub-PR accidentally opened against `dev` pushes a half-finished slice onto the integration branch and from there toward `main`, breaking the "`main` is always releasable" invariant.
- **Integrate from `dev` frequently.** The epic branch is long-lived, so it drifts from `dev` as other work lands. Merge `dev` → epic branch on a regular cadence (and cascade into the open sub-branches), so the final promotion is a small reconciliation instead of a large one. Integrate early, integrate often — do not let an epic branch sit for weeks.
- **Merge into the epic branch; never rebase it.** Rebasing the integration branch orphans the sub-branches based on it.
- **Manually close each sub-issue when its sub-PR merges into the epic branch.** Because `Closes` only fires on `main` (above), sub-PRs into the epic branch will *not* auto-close their issues. Closing them by hand at integration is what keeps the epic's sub-issue progress bar live — and that bar is your "is the deliverable ready?" signal. The closure means "this slice is code-complete and integrated"; it ships when the epic ships.
- **The epic issue `#E` closes at release.** Close it by hand when the release tag that ships it is cut, since no keyword fires on a tag. Do not put `Closes #E` in a promotion PR. So sub-issues close at *integration*, and the epic closes at *release*. Sub-issues closing on the epic branch are the deliberate, narrow exception to the close-on-merge rule above: the only place an issue closes before reaching `main`.
- **The epic branch is deploy-silent.** Pushing the epic branch deploys nothing, and sub-PRs into it get no environment. The integrated whole reaches `dev` (and local validation) when the epic branch merges to `dev`, then `main` (cross-repo system test) at the next promotion. It gets its cloud test window at its release candidate tag (see *Deployment lifecycle*).
- **SR&ED work stays 1:1.** The epic model is a non-SR&ED convenience. A SR&ED research issue is its own branch with its own granular commit trail (its Experiment Log *issues* are children, not branches) — don't fold SR&ED investigations onto an epic branch, or you blur the per-issue evidence the claim depends on.

#### Cross-repo epic — no shared branch

When an epic spans repos (Auth MVP-2 — Entra + ACA + Key Vault infra in `xpq-infra`, interleaved with BFF changes in `xpq-api` — is the canonical example), there is **no git branch that spans both repos**. The nested-branch mechanic above does not apply; coordination lives entirely in the tracking issue.

- **The epic `#E` lives in one repo; its sub-issues live in whichever repo does the work.** `#E`'s body lists them as a checklist (cross-repo references render and tick across repos). Order the list — it is the apply sequence (infra that must exist first sits above the app change that needs it).
- **Each sub-issue follows the ordinary feature → `dev` flow in its own repo.** No epic branch; each repo's `dev` integrates its own slice. The `commit-msg` hook is satisfied with no change — every commit is still `#<sub-issue>` on a `<sub-issue>-slug` branch.
- **Each repo promotes independently and often.** An infra slice can sit on `xpq-infra` `main` while its app slice is still on `xpq-api` `dev`. Neither is in cloud, because cloud waits for the release tags. Every slice that reaches `main` must still be inert when released, so an unrelated release of that repo can't ship it half-wired.
- **Completion = all sub-issues across all repos on their `main`s,** system-tested together locally. Then cut a release **in each affected repo**. These tags are the atomic unit and must reach **staging together**, so the staging workflow builds from the set (app image(s) + the tagged Bicep), not from one repo in isolation. Sequence the prod releases in issue order (infra first) so prod applies in dependency order. Staging, built fresh from Bicep, is order-insensitive by construction.
- **`Closes #sub`** rides each repo's own promotion PR, so sub-issues close when they reach `main`. **`#E`** is closed by hand when the last release tag is cut.

### The `#4`-class exception

Trivial fixes (typos, formatting, doc cleanups) tracked under a repo's standing "Trivial fixes" issue are exempt from the promotion ceremony: a single branch, a direct PR, no epic, no sub-issue bookkeeping. Reserve this for genuinely trivial, non-feature changes only.

## Time tracking

CRA wants hours attributable to specific SR&ED work packages, not bulk "I coded today."

Recommended minimum:
- End-of-day markdown journal entry in the `.github` repo under `journal/YYYY/MM/DD.md`.
- Two sections: "SR&ED time" (with `WP{n}` tags and issue references) and "Non-SR&ED time."
- One sentence per entry is enough. Contemporaneous > polished.

If using a tool (Toggl, Harvest, etc.), put the issue number in the description so time entries map back to research issues cleanly at claim time.

(Superseded: the journal/ approach above was replaced by the XP Quest Time Tracker widget +
`daily_git_summary.sh` + the `xpquest-daily-log` skill — see the workspace CLAUDE.md §6 for the
current pipeline.)

## Multi-machine daily-log merge

Robin develops on two machines (desktop **antman**, laptop **flash**, never simultaneously).
Both can accumulate Time Tracker hours and Claude session transcripts for the same calendar
date. Neither of those raw, per-machine inputs is synced between machines — that was
evaluated and deliberately skipped (2026-09-15): building sync infrastructure for Tracker
JSON and `.jsonl` transcripts wasn't worth it when the outputs already are shared.

The merge instead happens at the **shared output layer**. `Daily-Logs/` lives in OneDrive and
is the one thing both machines read and write for a given date:

- **Time Tracking hours**: `daily_git_summary.sh` reads back the `tracker-state` it hid in a
  base64-encoded comment at the end of the existing `github_summary-DATE.md` (keyed by project
  code + name, recording each host's last-known seconds — base64 rather than raw JSON so a
  tracker-controlled string can never contain a literal `-->` and break out of the HTML
  comment), folds in this machine's current Tracker JSON — replacing only this host's own
  prior entry, which is what keeps a same-host re-run idempotent — and re-sums. The visible
  `## Time Tracking` block is never partitioned by device; it stays organized purely by
  workstream/project, identical in shape to a single-machine run. See `XPQUEST_HOST_ID` in the
  script if a machine's `hostname` output ever needs overriding. A file that predates this
  comment (or whose comment is unreadable) has its visible bullets migrated in once, under a
  frozen `legacy` pseudo-host key, so pre-existing hours are never silently dropped the next
  time that file is rewritten.
- **Session content, commits, SR&ED narrative**: the `xpquest-daily-log` skill never
  regenerates an already-enriched `daily_log-DATE.md` / `sred_daily_log-DATE.md` /
  `client_daily_log-DATE.md` wholesale. It reads the existing file, computes this host's
  delta (new session bullets this host can see locally; any commit not already present), and
  adds only that delta **into the existing sections** — never into a device-specific block.
  Hand-filled SR&ED qualitative fields (`Technological Uncertainty`, `Hypothesis`, `Outcome /
  Result`, `Advancement of Knowledge`) are never touched by a merge run; only `[fill in]`
  placeholders Robin hasn't yet replaced are left as-is, everything else he's written is
  permanent once saved.
- **Commits**: recomputed fresh every run from `--branches --tags --remotes`, so they come out
  identical regardless of which machine runs the script, provided both have fetched — no
  merge bookkeeping needed there.

See XP-Quest/.github#41 for the design history and `scripts/tests/daily_git_summary.bats`
("Merge:" and "Starter log:" test groups) for the behavioral contract this rests on.

## Client-work data handling

Two hard rules, added after a 2026-09-09 incident: a Claude Code session backfilling missing
`client_daily_log` dates wrote a raw bash script that hardcoded a client's project description
and full client name directly into 19 files, copied from one existing sample file rather than
derived from the Time Tracker export. The value didn't exist anywhere in the Tracker's data
model (confirmed by DB inspection — the project's description field is immutable and blank,
and the app has no code path that ever updates it) — it was authored by the session itself.
Separately, the real client name and project code had also been committed as test fixture data
in `scripts/tests/daily_git_summary.bats` (see XP-Quest/.github#49 for both fixes).

1. **No hardcoded business-data literals in any script, ad-hoc or otherwise.** A script that
   writes to a log, database, or file must derive every value (description, client name,
   hours) programmatically from that run's actual evidence source — never a literal typed or
   copied in from another day, another file, or an earlier conversation. If the evidence
   source doesn't carry a field, leave it blank; don't backfill it by hand inside a script.
2. **No client-identifying data anywhere in a public-facing XP-Quest repo — git-tracked
   content or GitHub metadata.** `.github`, `xpq-web`, `xpq-api`, `xpq-infra`, and
   `rdcoe/timetracking` are all public or semi-public. That covers two distinct categories:
   (1) git-tracked content — code, test fixtures, comments, commit messages — and (2)
   GitHub-hosted metadata that isn't part of the git history at all — issue bodies, PR
   descriptions, review comments. Client work product (names, descriptions, hours) lives
   exclusively under `Daily-Logs/<Client>/` in the OneDrive-backed workspace, never in a repo
   or its issue tracker. Tests and examples use a generic placeholder (`acme-corp`), never a
   real client name.

Both rules are also stated in the `xpquest-daily-log` skill itself, deliberately redundant with
this doc: per-device Claude memory does not sync across machines, so a rule that lives only in
one device's memory is invisible on the other. These rules live in git-tracked files precisely
so a fresh session, on any host, sees them.

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
