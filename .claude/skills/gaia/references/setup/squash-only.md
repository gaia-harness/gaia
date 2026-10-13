# Squash-only merge question

`/setup-gaia` Phase 3.7 reads this file, whole, once its gates say the question is owed. Control returns to Phase 3.7 of `setup-gaia.md`, which falls through to Phase 4.5.

Every record line below is gated on `MAY_RECORD_PROJECT` being `admin`; declare it, `OWNER` and `REPO` with the cached values in each call. Read the current settings:

```bash
CURRENT="$(gh api "repos/$OWNER/$REPO" --jq '{allow_merge_commit, allow_rebase_merge, allow_squash_merge, squash_merge_commit_title, squash_merge_commit_message}')"
if printf '%s' "$CURRENT" | jq -e '. == {"allow_merge_commit": false, "allow_rebase_merge": false, "allow_squash_merge": true, "squash_merge_commit_title": "PR_TITLE", "squash_merge_commit_message": "COMMIT_MESSAGES"}' >/dev/null 2>&1; then
  echo "Merges are already squash-only."
  [ "$MAY_RECORD_PROJECT" != admin ] || .gaia/cli/gaia setup record squash-only applied
else
  printf '%s\n' "$CURRENT"
fi
```

If they already match the PATCH below, the block prints `Merges are already squash-only.` and records `applied`; fall through to Phase 4.5. Otherwise AskUserQuestion:

> This repository allows merges that bypass the squash path, or squashes under a title other than the PR title. A merge commit, a rebase merge, or a default squash title can land a non-Conventional subject on the default branch, so the PR title lint stops describing what lands. Squash-only turns off merge commits and rebase merges, and has every squash commit take the PR title as its subject and the branch's commit messages as its body.
>
> - **Make merges squash-only** (Recommended)
> - **Skip** (keep the current merge settings)

On Make merges squash-only:

```bash
gh api -X PATCH "repos/$OWNER/$REPO" --input - <<'JSON'
{"allow_merge_commit": false, "allow_rebase_merge": false, "allow_squash_merge": true, "squash_merge_commit_title": "PR_TITLE", "squash_merge_commit_message": "COMMIT_MESSAGES"}
JSON
```

Re-run the read above: when it prints `Merges are already squash-only.`, the PATCH is verified and the block records `applied`. On a failed PATCH or a read-back that does not match, record nothing, print the error and the manual path, `Settings → General → Pull Requests` on `https://github.com/<owner>/<repo>/settings`, and continue; do not halt.

On Skip, change nothing on GitHub, and record the decision:

```bash
[ "$MAY_RECORD_PROJECT" != admin ] || .gaia/cli/gaia setup record squash-only declined
```
