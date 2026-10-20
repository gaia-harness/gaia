# Audit recall corpus

A differential recall test for the Code Audit Team. The committed corpus runs on a before bundle and an after bundle, every entry twice per bundle, and the after bundle may not reliably miss what the before bundle reliably finds. Selection, checking and dry runs call no model; only `run-recall.sh` without `--dry-run` spends.

## Files

- `corpus.json`: the corpus (schema 1): `seed`, `selected_against` (the `origin/main` sha at selection), `selection_bundles` (`before`, `after`), `entries` and `skipped`.
- `select.mjs`: selects the corpus, or re-checks it (`--check`).
- `build-tree.sh`: builds one real entry's replay tree.
- `run-recall.sh`: runs every entry once against one bundle.
- `score.mjs`: the differential verdict over two before runs and two after runs.
- `lib/prng.mjs`: the seeded PRNG (mulberry32) and Fisher-Yates shuffle; the same seed gives the same order on any machine.
- `lib/replay-range.mjs`: the git questions selection asks (head resolution, base rule, line mapping).
- `lib/runs.mjs`: transcript helpers `run-recall.sh` calls (member done, specialist replies).
- `planted/`: the planted patches and `entries.json`, appended to every selection.
- `fixtures/score/`: committed run directories the scorer's tests read.

## Bundles

- **before**: the tree at the merge-base of the execution branch with `origin/main`.
- **after**: the execution branch HEAD.
- **selection**: the before bundle plus the provisional after bundle (the closest committed after state at selection time). Before any recall spend, every committed real entry is rebuilt against the final before and after bundles with `select.mjs --check`; an entry failing there is reselected deterministically against the final bundles and the corpus recommitted on its own.

## Select

```bash
node .gaia/tests/audit-recall/select.mjs --source <mined findings json> --repo <maintainer checkout> \
  --bundle-before <before sha> --bundle-after <after sha> --out .gaia/tests/audit-recall/corpus.json
```

`--repo` is a standalone clone of the maintainer repository whose `origin/main` is current; selection only reads it. Real entries come from the mined findings file (one row per member finding from past audit sessions):

1. Eligible: severity `minor`, `warning`, `major` or `error`; the member is an active `code-audit-*` definition on `origin/main`, minus the retired prose member; the mined sha is an ancestor of `origin/main` (else a `skipped` row `unreachable`); the title names no working-document id or machine-local path.
2. Shuffled with seed 122 (`--seed` overrides it), the source file's order going in.
3. Per member, walking the shuffled order, the first ten whose replay tree builds against both bundles and whose line sits on the same line of both replay trees as at the head, or every eligible one when fewer.
4. Planted entries from `planted/entries.json` are appended, so re-running selection on the same inputs writes a byte-identical file.

**Head resolution.** The miner recorded the audit's base, not the reviewed head. When that sha sits on `origin/main`'s first-parent chain, the head is the oldest later first-parent commit (within twenty) that touches the finding's path and was committed after the audit; a finding no such commit explains is skipped `head-unresolved`.

**Base rule.** With `M` the oldest first-parent `origin/main` commit containing the head: `head^1` when `M` is the head (a squash or direct commit), else `git merge-base M^1 head` (a merged branch).

Skip reasons: `unreachable`, `title-carries-local-reference`, `head-unresolved`, `duplicate-of <id>` (same member, head, path, class prefix and a line within the match window), `base-unresolvable`, and per bundle `patch-conflicts-overlay (<bundle>)`, `line-unmappable (<bundle>)`, `line-moved-by-overlay (<bundle>)` or another `build-tree.sh` failure token.

`--check` rebuilds every real entry already in `--out` against the two given bundles without reselecting, prints each failure and exits 2 when any fails, 0 otherwise.

## Build

```bash
bash .gaia/tests/audit-recall/build-tree.sh --repo <maintainer checkout> --bundle <sha> --base <sha> --head <sha> --clone <dir>
```

The clone comes from the measurement toolkit's `prepare-scratch-clone.sh` at the base: a standalone clone, never a linked worktree (a linked worktree's `.gaia/local` is a symlink into the live audit store), with the maintainer marker stripped and the sentinel written. Why the marker goes: the `Scratch-clone rule` section of `../audit-cost/README.md`. On `main`, the base's harness (`.claude`, `.github/audit`, `wiki`, `frontend/.claude`, `.gaia`) is replaced by the bundle's, the marker is stripped again when the bundle restored it, and the result is committed. The change `base..head` is applied with `git apply --3way` on a `replay` branch; a conflict exits 4 `patch-conflicts-overlay`. The bundle's `resolve-audit-base.sh` must resolve the replay `main` in the clone.

## Run

```bash
bash .gaia/tests/audit-recall/run-recall.sh --bundle before|after --run <k> --clone <dir> --scaffold <throwaway> \
  --out <dir> --max-usd <n> [--dry-run] [--repo <maintainer checkout>] [--bundle-sha <sha>] [--corpus <corpus.json>]
```

Each real entry builds its tree under `--clone` (a build failure exits 2: an input error, never a miss), then one headless session dispatches only the entry's member, directly; the audit router is never involved, so its light route for a first frontend dispatch does not apply. Planted entries run on `--scaffold`, a throwaway adopter scaffolded from the bundle under test carrying the `.gaia/local/measurement-scratch` sentinel (`../audit-cost/README.md`, `Building a bundle`), one branch per patch. Each entry's directory gets the findings sidecar, the transcripts, `measure.json` and last `result.json`; `summary.json` records the run's cost and specialist no-op count.

**Spend cap.** `--max-usd` is required. After every entry the measured cost is added up; at the cap the run stops (exit 3) with `summary.json` marked partial.

`--dry-run` builds every real entry's tree and pipes a synthetic `Agent` PreToolUse payload for the entry's member into the tree's own `audit-loop-bound.sh`; a `BLOCKED` deny exits 1. It calls no model and writes nothing outside `--clone`.

## Score

```bash
node .gaia/tests/audit-recall/score.mjs --before <run1> <run2> --after <run1> <run2> [--corpus <corpus.json>]
```

Matching is deterministic: same path and a line within 5. Member entries need a sidecar finding whose class prefix matches; specialist entries need the specialist's own reply (found with `classifyChild`), never the member's merged report; refuter entries read the verdict token of the refuter whose `Location:` matches. An entry gates when both before runs find it (refuter: both before verdicts agree); the after bundle fails it only when both after runs miss it (refuter: both after verdicts differ). Exit 0 pass, 1 a recall failure, 2 a usage or input error (a missing run directory or entry result is never a pass).

**Re-pin rule.** When every failure is a specialist entry (`specialist_failures_only`), the specialist type is re-pinned to Sonnet once and the corpus re-run. A member or refuter miss, or any miss after the re-pin, fails the gate.
