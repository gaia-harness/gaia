# Squash-only merge question

`/setup-gaia` Phase 3.7 reads this file, whole, once its gates say the question is owed. Control returns to Phase 3.7 of `setup-gaia.md`, which falls through to Phase 4.5.

Read the current settings:

```bash
gh api "repos/<owner>/<repo>" --jq '{allow_merge_commit, allow_rebase_merge, allow_squash_merge, squash_merge_commit_title, squash_merge_commit_message}'
```

If they already match the PATCH below, print `Merges are already squash-only.` and fall through to Phase 4.5. Otherwise AskUserQuestion:

> This repository allows merges that bypass the squash path, or squashes under a title other than the PR title. A merge commit, a rebase merge, or a default squash title can land a non-Conventional subject on the default branch, so the PR title lint stops describing what lands. Squash-only turns off merge commits and rebase merges, and has every squash commit take the PR title as its subject and the branch's commit messages as its body.
>
> - **Make merges squash-only** (Recommended)
> - **Skip** (keep the current merge settings)

On Make merges squash-only:

```bash
gh api -X PATCH "repos/<owner>/<repo>" --input - <<'JSON'
{"allow_merge_commit": false, "allow_rebase_merge": false, "allow_squash_merge": true, "squash_merge_commit_title": "PR_TITLE", "squash_merge_commit_message": "COMMIT_MESSAGES"}
JSON
```

Re-run the read above and confirm the five values match the PATCH. On a failed PATCH or a read-back that does not match, print the error and the manual path, `Settings → General → Pull Requests` on `https://github.com/<owner>/<repo>/settings`, and continue; do not halt.

On Skip, change nothing.
