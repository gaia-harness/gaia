# /gaia-debt: resume a stopped fix

A fix that stopped after its branch was cut and before `gh pr create` leaves its issue claimed, and `## Validate named numbers` in `debt/named.md` refuses a claimed issue. `debt.md` routes here, ahead of that refusal, when `bash .gaia/scripts/debt-stuck-fixes.sh --issue <N>` printed `<N>`, a tab and the branch name; the rule that script applies is in its header. The same script feeds `gaia-next.sh pick` its `debt-resume` job.

Contents: Resume.

## Resume

1. **The unit is the branch's members.** `. .gaia/scripts/branch-name-lib.sh`, then `gaia_branch_members <branch>`: every member that is still open and carries `in-progress`. A batch branch resumes whole. The claim, the security screen, the staleness screen and the spec screen ran before the branch was cut, so nothing here re-claims or re-screens.
2. **Re-enter the branch.** Apply `.claude/skills/gaia/references/isolation.md` `### Resume`. When no worktree holds the branch, `git checkout <branch>` in the main checkout (HEAD on the default branch and clean, else report and stop). The tree it lands in is `RESOLVED_ROOT`.
3. **Read what the branch holds**: `git log` of `refs/remotes/origin/<default>..HEAD`, `git status` and the diff, in `RESOLVED_ROOT`. Finish each member's fix from its issue body and comments, then continue at `## Resolve the selected unit` step 4 in `debt.md` (the Quality Gate, commit and push), step 5 (the draft PR) and `## Drive the PR to merge`.
