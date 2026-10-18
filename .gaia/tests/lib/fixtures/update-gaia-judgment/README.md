# Judgment pass fixtures

Inputs for a manual or eval run of the /update-gaia execution agent's judgment pass (`.claude/skills/update-gaia/references/merge-execution.md`, "The judgment pass"). The deterministic suites cannot judge prose, so these pairs confirm the classification by hand. Each directory holds a baseline (`B.md`), the adopter's copy (`A.md`) and GAIA's latest copy (`L.md`) of one file. `git merge-file -p A.md B.md L.md` merges both pairs cleanly, which is the point: a clean text merge is not enough on its own.

## `independent/`

- Adopter (B to A): adds a team naming rule under Naming.
- GAIA (B to L): adds a focus-order rule under Accessibility.
- Expected classification: independent concerns. Status `auto-merged`, no question; the clean merge is written to the file and the review summary names it.

## `same-concern-gaia/`

- Adopter (B to A): flags a fetch call in a loader with no timeout (under Data loading), and separately adds a Storybook dark-mode check (under Styling).
- GAIA (B to L): requires a timeout on every network request (under Network).
- Expected classification: the timeout lines are the same concern, and GAIA's covers it (every request, not only loader fetches). Status `open`, one item of kind `same-concern-gaia`, options `combine, keep, gaia, defer`. The `combine` candidate is GAIA's timeout rule with the adopter's timeout line dropped and the adopter's unrelated dark-mode line kept; it carries no conflict marker. Taking the clean text merge instead would leave two overlapping timeout rules in the file.
