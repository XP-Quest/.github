# RSE SR&ED Tracking Conventions

This document describes how Red Shirt Engineering tracks technological uncertainty investigations across GitHub for the purpose of a Canadian SR&ED claim (federal) stacked with the Ontario Innovation Tax Credit (OITC).

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

## Commit and PR conventions

- Commit messages referencing SR&ED work include the issue number: `chore(rag): tune chunk overlap — refs #42`
- PRs set "Contribution type" in the template and link the parent research issue.
- Prefer many small commits over large ones during investigation phases — they form the timeline evidence.

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
