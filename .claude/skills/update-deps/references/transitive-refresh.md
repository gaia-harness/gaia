### Transitive refresh instructions

Operate on the root workspace and its `frontend` package only: run every `pnpm` command from the repository root, never with `-r` or `cd`; `-C frontend` is the one allowed path argument. Frozen names: `{FROZEN_NAMES}`.

1. **Snapshot** the files the refresh could touch, and the direct dependencies' resolved versions. Run each command below as its own call, in order. **If any of them exits non-zero or is refused, stop here:** do not run step 2 or anything after it, change nothing, and report `Not run (snapshot failed: <command>: <first error line>)`. A refresh with no baseline can only be undone by resetting to HEAD, which also throws away the run's uncommitted Wave A and Wave B edits.

   The baseline is a git commit object, never a file copy. The project's settings deny editing `pnpm-lock.yaml`, and Claude Code refuses a `cp` of the lockfile in either direction, wherever its other path points, and a redirect that writes to it. git commands that read the lockfile or restore it are not refused.
   ```bash
   git stash create
   ```
   It prints the id of a commit that holds every tracked file as the working tree has it, the uncommitted wave edits included, and leaves the working tree, the index and the stash list untouched. It prints nothing when no tracked file has changed; then run:
   ```bash
   git rev-parse HEAD
   ```
   Carry the id that was printed as the literal `<baseline>` in every later step: shell variables do not survive between calls. Then:
   ```bash
   git cat-file -e <baseline>:pnpm-lock.yaml
   mkdir -p /tmp/update-deps-refresh
   pnpm -C frontend ls --depth 0 --json | jq -e '.[0] | (.dependencies // {}) + (.devDependencies // {}) | map_values(.version)' > /tmp/update-deps-refresh/direct.json
   ```
2. **Refresh:**
   ```bash
   pnpm cache delete '*'
   pnpm -C frontend update --no-save
   ```
   The first line drops pnpm's cached package metadata. pnpm treats metadata it cached within the release-age window as complete, which holds for every version the window admits but not for one a `minimumReleaseAgeExclude` entry admits early: a release published since that fetch is otherwise invisible to the refresh, which then exits 0 having moved nothing. pnpm's metadata cache is per machine, not per project, so this clears it for every project on the machine. That is safe: the cache holds only registry metadata, never packages or lockfiles, so the cost is a refetch on each project's next resolve, and the whole-tree refresh here measures no slower with an empty cache. `--no-save` leaves every range in `package.json` as declared, so direct specs stay with Waves A and B; pnpm's default depth is unlimited, so this re-resolves the whole tree. Do not pass `--depth Infinity`: pnpm takes only an integer depth and exits on that value. Do not use `pnpm update --latest` (it ignores ranges) or `pnpm dedupe` (it moves a transitive only when that removes a duplicate). pnpm applies `minimumReleaseAge` while it resolves, so no version younger than the window lands; never add a `minimumReleaseAgeExclude` entry or change any setting to get a version through. If the command exits non-zero, revert (step 6) with reason `install error: <first error line>`.
3. **Check what it touched.**
   - `package.json`, `frontend/package.json`, and `pnpm-workspace.yaml` must be byte-identical to the baseline:
     ```bash
     git diff --quiet <baseline> -- package.json frontend/package.json pnpm-workspace.yaml
     ```
     Exit 1 means pnpm rewrote a range or recorded a release-age exemption: revert with reason `rewrote <file>`, naming the file `git diff --stat <baseline> -- package.json frontend/package.json pnpm-workspace.yaml` lists.
   - Re-run the step 1 `pnpm -C frontend ls` line into `/tmp/update-deps-refresh/direct-after.json` and compare each frozen name's version with `direct.json`. A frozen name whose version changed means the refresh moved a held or snoozed package inside its range: revert with reason `moved frozen <name> (<from> -> <to>); pin it to an exact version in package.json to let the refresh run`.
4. **List what moved**, from the lockfile's `packages:` keys before and after. Write out the baseline's lockfile first, as its own call:
   ```bash
   git show <baseline>:pnpm-lock.yaml > /tmp/update-deps-refresh/lock-before.yaml
   ```
   Then:
   ```bash
   lock_keys() {
     awk '/^packages:/{p=1;next} /^[^ ]/{p=0} p && /^  [^ ]/{k=$0; sub(/^  /,"",k); sub(/:$/,"",k); gsub(/\047/,"",k); print k}' "$1" | sort -u
   }
   lock_keys /tmp/update-deps-refresh/lock-before.yaml > /tmp/update-deps-refresh/keys-before
   lock_keys pnpm-lock.yaml > /tmp/update-deps-refresh/keys-after
   { comm -23 /tmp/update-deps-refresh/keys-before /tmp/update-deps-refresh/keys-after | sed 's/^/- /'; comm -13 /tmp/update-deps-refresh/keys-before /tmp/update-deps-refresh/keys-after | sed 's/^/+ /'; } |
     awk '{ i=match($2, /.@[^@]*$/); n=substr($2,1,i); v=substr($2,i+2); if ($1=="-") from[n]=(n in from ? from[n] ", " : "") v; else to[n]=(n in to ? to[n] ", " : "") v; seen[n]=1 }
          END { for (n in seen) printf "%s\t%s\t%s\n", n, (n in from ? from[n] : "(new)"), (n in to ? to[n] : "(removed)") }' | sort
   ```
   Each row is `package<TAB>from<TAB>to`; a package locked at several versions lists them comma-separated. Empty output means nothing moved: report `Nothing moved` and stop, there is nothing to gate.
5. **Quality gate**:
   ```bash
   pnpm typecheck
   pnpm lint
   pnpm test --run
   pnpm pw
   pnpm build
   ```
   On any failure, revert (step 6) with reason `quality gate failed: <step>`. No remediation pass: one gate run cannot say which of the moved packages broke it.
6. **Revert** restores the whole refresh, never part of it, from the baseline, leaving the index as it was. Run each line as its own call:
   ```bash
   git restore --source=<baseline> --worktree -- package.json pnpm-lock.yaml pnpm-workspace.yaml frontend/package.json
   pnpm install --frozen-lockfile
   git diff --quiet <baseline> -- package.json pnpm-lock.yaml pnpm-workspace.yaml frontend/package.json
   ```
   The last line exits 0 when all four files match the baseline again.

Report back: the outcome (`landed`, `Nothing moved`, `Reverted (<reason>)`, or `Not run (snapshot failed: <reason>)`), the step 4 rows (for a revert, the rows that would have moved, when step 4 ran), and the quality gate results.
