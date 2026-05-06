# XP Quest — Copilot Instructions

XP Quest Inc. (XPQ) is a Canadian CCPC building a SaaS that matches candidates to recruiters
via conversational AI and NLP queries. Solo founder. All work must maintain SR&ED
(Scientific Research & Experimental Development) eligibility traceability for CRA claims.

---

## Issue-Driven Workflow (mandatory)

1. **Create a GitHub issue before branching.** Every unit of work traces to an issue.
2. **Branch name:** `<issue-number>-<kebab-slug>` — e.g., `42-chunker-baseline`
3. **Commit subject:** `#<issue-number>: <imperative description>` — e.g., `#42: add FixedSizeChunker baseline`
   - The commit-msg hook enforces this format at `git commit` time.
4. **No commits to main directly.** Always PR from a feature branch.

## Repository Layout

Polyrepo under `~/xpquest/` (WSL path). Each repo has its own CI and deploy target.

| Local dir      | GitHub remote          | Purpose                      |
|----------------|------------------------|------------------------------|
| `xpq-org/`     | XP-Quest/.github       | Org health, scripts, templates |
| `xpq-web/`     | XP-Quest/xpq-web       | React SPA (Azure SWA)        |
| `xpq-api/`     | XP-Quest/xpq-api       | Quarkus BFF (AKS)            |
| `xpquest-spa/` | XP-Quest/xpquest-spa   | Consulting/marketing site    |

## SR&ED Work Packages

Code touching these areas may qualify as SR&ED. Always reference the WP in the issue.

| ID  | Title                                         |
|-----|-----------------------------------------------|
| WP1 | Semantic Chunking Strategy                    |
| WP2 | Relevance Gate Threshold Calibration          |
| WP3 | Ambiguity Detection Heuristics                |
| WP4 | Conversational Augmentation Pipeline          |
| WP5 | Dual-Score Job Description Correlation Engine |
| WP6 | Multi-Tenant Quota Enforcement + Cost Attribution |

**NOT SR&ED:** React components, routing, state, forms, styling; REST CRUD endpoints;
ORM/schema/migration; auth flows; billing; CI/CD; standard observability.

**When in doubt:** create an Engineering Task issue, not an SR&ED Research issue.

## Labels

`sred`, `research`, `experiment`, `engineering`, `wp1`–`wp6`, `cross-cutting`

## Issue Templates (use these)

- **SR&ED Research Issue** — long-lived investigation with hypothesis, uncertainty statement, experimental plan
- **Experiment Log Entry** — one per experimental run; references a parent research issue
- **Engineering Task** — routine work; includes SR&ED screening checkbox

## Tech Stack

- **Frontend:** React SPA (TypeScript, Vite/CRA)
- **Backend:** Quarkus (Java 21), groupId `ca.xpquest`, artifactId `xpq-api`
- **Cloud:** Azure (AKS for API, Static Web Apps for SPA)
- **Auth:** AKS ingress + OIDC filters
- **DB:** PostgreSQL + pgvector (vector search); relational schema TBD
- **Dev OS:** WSL2 (Ubuntu) on Windows

Prefer Java for backend examples. Use the most appropriate language for the problem.

## Scripts (in xpq-org/scripts/)

| Script                      | Purpose                                                  |
|-----------------------------|----------------------------------------------------------|
| `daily_git_summary.sh DATE` | Commit summary for one date, grouped by issue            |
| `historical_git_summary.sh` | Batch daily summaries from checkpoint to yesterday       |
| `xpq-time.sh start/stop N`  | SR&ED time tracking; writes to `journal/.time-log.csv`  |
| `reconcile_commit.sh`       | Assign untracked commits to an issue retroactively       |
| `install-hooks.sh`          | Install commit-msg and other Git hooks into a repo       |

## Constraints

- Solo founder — contemporaneous evidence (issues, commits, journal, time log) is the CRA claim.
- Never inflate SR&ED labeling. Routine engineering wrongly tagged is a larger risk than under-tagging.
- CCPC status governs 35% refundable ITC rate — share structure decisions need accountant sign-off.
- IP must be assigned to the corporation before expenditures are claimable.
