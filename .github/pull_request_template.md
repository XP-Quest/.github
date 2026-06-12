## Summary

<!-- What changes, and why. Two or three sentences. -->

## SR&ED Linkage

<!--
If this work contributes to a SR&ED research issue, link it and describe what evidence this PR adds
(hypothesis test, eval data, experiment run, design iteration, etc.).
If it's routine engineering, mark "Not SR&ED-eligible" and move on.
-->

- Related research issue: #
- Contribution type: <!-- hypothesis test | evidence artifact | design iteration | experiment run | N/A — routine engineering -->

## Lifecycle

<!--
Base & closing — see SR_ED_CONVENTIONS.md "PR and issue lifecycle":
- feature → dev (or sub-issue → epic branch): base is dev / the epic branch. Reference the
  issue with a plain #NN. Do NOT use Closes here — it would not fire anyway (only main closes).
- PR to main (dev→main promotion in two-track repos, feature→main in single-track xpq-org):
  this is the close point. Put the literal keyword on the Merge action line below, repeated
  per issue (GitHub closes only the first one otherwise): Closes #NN, Closes #NN, …
  A bare "#NN" does NOT close — the keyword must directly precede each number.
  The pr-lifecycle guard fails the PR if no honoured keyword is present.
-->

- Base branch:
- Merge action (PRs to main only): Closes #<n>[, Closes #<n>, …]

## Test Plan

- [ ]
- [ ]

## Notes for Reviewer (self, for now)

<!-- Anything surprising, any trade-offs taken, any follow-up worth capturing. -->
