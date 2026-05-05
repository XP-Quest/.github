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
3. Create branch `42-semantic-chunker-baseline` off `main`.
4. Implement a `FixedSizeChunker` (512 tokens, 64 overlap).
5. Post comment to issue #42:
   > **Commit a3f8c1d** — Added a `FixedSizeChunker` at 512/64. 512 chosen to match the embedding model's context window without truncation. The 64-token overlap is a heuristic from the Anthropic RAG cookbook example, not yet calibrated — calibration belongs to a later experiment. Token-count metrics deliberately split into a separate commit so the chunker can be reviewed in isolation. Next: add metrics so we can compare strategies empirically (WP1 has no calibration without them).
6. Commit subject: `#42: add FixedSizeChunker baseline at 512/64`
7. Continue on the same branch — add metrics, post a second verbose comment, commit `#42: add token-count metrics to chunker output`.
8. Open a PR; PR body's SR&ED Linkage section points to issue #42.

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

**Layer 3 — Human-judged reconciliation.** Commits that survive Layers 1 and 2 land in a `## (untracked)` section of the daily log. These are the residual cases requiring judgment.

### Layer 3 procedure (the manual judgment piece)

When `daily_git_summary.sh` emits a `## (untracked)` section, work through each commit:

1. **Read the diff** (`git show <sha>` in the relevant repo).
2. **Decide:**
   - *Attach to existing issue* if the diff clearly fits the scope of an open or recently-closed issue.
   - *File a new retroactive issue* if no existing issue fits. Use the appropriate template (`engineering-task` or `sred-research`); apply the `retroactive` label so retroactive filings are countable. Filing the issue retroactively is itself useful signal at claim time — it shows where process slipped.
   - *Never* attach by superficial keyword overlap. For SR&ED, attaching to the wrong WP issue is worse than leaving the commit orphaned, because it pollutes evidence.
3. **Run the helper** with the chosen issue number:

   ```bash
   cd <repo>
   ../xpq-org/scripts/reconcile_commit.sh <sha> <issue> --repo XP-Quest/<repo>
   ```

   The helper lives in the org-level `xpq-org` checkout, but it must be executed from inside the target repo so `git rev-parse` resolves the SHA in the correct repository. It opens `$EDITOR` for the verbose comment (Rule 4 standard applies — this comment must be as complete as if it had been written at commit time), posts it to the issue, and appends the SHA to `journal/.reconciled` so the daily log skips it on the next run.
4. The next daily run will no longer flag the SHA. The reconciled commit appears nowhere in the regular sections — the audit trail lives entirely in the issue thread, by design.

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
