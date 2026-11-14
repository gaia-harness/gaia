# Overlap pass

The overlap pass no longer runs. A plan with a test-design table is checked by the drift check, and an older plan has nothing to run here.

An orchestrator reaching this step appends `## Overlap pass` and `Result: retired` to the plan's `PROGRESS.md`, then goes on to the next step.
