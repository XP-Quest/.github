# XP Quest — Org Health Repository (.github)

This is the GitHub org-level `.github` repository for XP-Quest. GitHub applies its default
community health files only from a public repository named `.github`. It holds:

1. **GitHub templates** — issue forms and the PR template, applied to every XP-Quest repo that
   does not define its own.
2. **Conventions** — `SR_ED_CONVENTIONS.md`: issue types, labels, branch and commit rules, the PR
   and issue lifecycle, and SR&ED screening.
3. **Reusable workflows** — `pr-lifecycle` (closing-keyword guard) and `branch-cleanup` (delete
   merged feature branches), called by a thin caller in each repo.

Tooling (daily-log scripts, git and Claude Code hooks, skills) lives in the private
`XP-Quest/xpq-devops` repo.

---

## Repository layout

```text
.github/
├── .github/
│   ├── ISSUE_TEMPLATE/
│   │   ├── sred-research.yml       SR&ED research issue (long-lived investigation)
│   │   ├── experiment-log.yml      One experimental run; references a parent issue
│   │   ├── engineering-task.yml    Routine work; includes SR&ED screening checkbox
│   │   └── config.yml              Disables blank issues
│   ├── workflows/
│   │   ├── pr-lifecycle*.yml       Closing-keyword guard (reusable + this repo's caller)
│   │   └── branch-cleanup*.yml     Delete merged feature branches on merge to main (reusable + caller)
│   ├── pull_request_template.md    PR template with SR&ED linkage field
│   └── copilot-instructions.md     Copilot context for this repo
│
├── scripts/
│   ├── branch-cleanup.sh           Run by branch-cleanup-reusable.yml (checked out at the workflow's commit)
│   └── tests/                      bats tests for branch-cleanup.sh (scripts/tests/run_tests.sh)
│
├── SR_ED_CONVENTIONS.md
└── README.md
```

`branch-cleanup.sh` stays here because the reusable workflow checks it out with the calling
repo's `GITHUB_TOKEN`, which can read only public repositories outside the caller.

---

## GitHub org wiring

The remote is `XP-Quest/.github`; the local clone is `~/xpquest/xpq-org`.

```bash
gh repo clone XP-Quest/.github ~/xpquest/xpq-org
```

Templates propagate to every XP-Quest repo that does not define its own
`.github/ISSUE_TEMPLATE/`. This repo is single-track: feature branch → PR → `main`.
