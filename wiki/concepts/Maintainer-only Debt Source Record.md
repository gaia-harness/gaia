---
type: concept
status: active
created: 2026-10-28
updated: 2026-10-28
promoted_at: 2026-10-27T19:11:03Z
promoted_hash: sha256:c163e621102598872942dd31a2e57a4a75f8f7b08dc182d071c93b1e7569c9db
pr_number: 3141
tags: [promoted, concepts]
---
# Maintainer-only debt source record

In GAIA's own repository, every tech-debt issue filed through `.gaia/scripts/file-tech-debt.sh` carries a source line on line 2 of its body, directly after the unchanged dedup key line: `<!-- gaia-debt-source: v1 branch=<value> -->`. `<value>` is the first 12 lowercase hex characters of the SHA-256 of the normalized branch name (`gaia_branch_normalize`, so `worktree-debt+1234-foo` and `debt/1234-foo` give the same digest), or `detached`, or `unknown` when the tree cannot be read or the digest fails. The raw branch name never appears in the body. The digest keeps names and working-doc ids out of public issue text; it is not a privacy guarantee, since a known name hashes to the same value.

## Behavior

### Resolution and retry

The branch resolves in this order: the finding JSON's `source_branch` (a JSON string; `""` means detached; any other type is ignored), then `file-tech-debt.sh file --source-branch <name>`, then the branch checked out in the tree that holds the running script (read with `symbolic-ref`, never `--short`, through `git -C` with `GIT_DIR`, `GIT_WORK_TREE` and `GIT_COMMON_DIR` unset). On a transient failure the retained retry copy gains `source_branch` when the finding lacks it, so a replay from a tree that has since moved records the first attempt's branch.

### Where the code lives

- `.gaia/scripts/debt-source-lib.sh` (release-excluded, sourced only) builds the line, computes the digest through an injectable SHA-256 hasher (`file-tech-debt.sh` passes its own `sha256_of_text`), resolves the tree state and the precedence, and rewrites the retry file.
- `file-tech-debt.sh` carries its source-line code wholly inside `# gaia:maintainer-only` regions: header prose, globals, the retry hook, the `--source-branch` arm, the resolve call before any `finish_*`, and the body-printer line. The only shipped-line change is the split of the key-line `printf` so the source line can sit between it and the blank line. The release scrub strips the regions, so a release tree prints line 1 then the blank line exactly as before.
- `.gaia/scripts/debt-source-report.sh` (release-excluded) reads issues and merged pull requests through `gh api --paginate` REST (never search-backed lists) and prints `filed --branch` (count plus `verdict pass|over` against a threshold, default 4), `baseline --since` (single-minor, multi-minor and other merged pull requests with filings per pull and per member) and `coverage --since` (keyed, sourced, missing, unknown, unkeyed, unattributed, `sound yes|no`). A failed or partial read, bad usage or a missing tool exits 2 with empty stdout and one stderr line.
- Docs: maintainer-only passages in the file-tech-debt skill's body schema, the debt re-grade reference (a body rewrite keeps the line on line 2) and [[Audit Disposition and Debt Fix]].
- Proof: a distribution scenario files from a staged release tree and asserts no source-line code, no `debt-source-*.sh` script and an empty line 2.

### Complete dedup list reads (shipped)

`file-tech-debt.sh` and `debt-dedup.sh` read the open and closed tech-debt lists through the shipped `.gaia/scripts/debt-list-lib.sh` (`gaia_debt_list_read`): paginated REST, pull requests dropped, `state_reason` mapped to the GraphQL `stateReason` spelling the callers read, and any failed or non-array page fails the read. No result limit or limit-fill heuristic remains.

### Rollout

An adopter rollout removes the maintainer-only markers of the filing-script regions and the doc passages, and the release-exclude entries for the library and the report; the pull request that introduced the record lists them under `## Rollout inventory`. It is gated on a dogfood record kept in the maintainer notebook: coverage sound after a 7-day grace window, then enough single-minor and multi-minor data.

## Divergence

Scope grew rather than narrowed: the complete-list dedup fix was not in the SPEC (it was to be filed as debt only) and was folded in at execution on the maintainer's approval, widened from `file-tech-debt.sh` to `debt-dedup.sh` through one shipped reader. A CHANGELOG entry was added for both changes, where the plan had decided none.
