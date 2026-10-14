---
name: update-gaia
description: Pulls the latest GAIA release into this project without clobbering customizations, with a three-way merge per file using .gaia/manifest.json classes. Trigger when the user clicks the statusline `Run /update-gaia` indicator or asks "update GAIA", "pull the latest GAIA", "apply the new GAIA release".
---

Pull the latest GAIA release into this project without clobbering customizations. Does a three-way comparison per file (adopter / baseline / latest) and respects explicit classes in `.gaia/manifest.json`:

- **`owned`**: GAIA controls fully.
- **`shared`**: GAIA seeds, you customize.
- **`wiki-owned`**: GAIA-seeded concept/decision/module wiki pages.
- **adopter-owned (implicit)**: anything not in the manifest, plus sentinels like `wiki/log.md`, `CHANGELOG.md`, `.gaia/VERSION`, `.gaia/manifest.json`. Never touched.

The first three take the same Step 7 rows. The class changes only two of them: which bucket a clean overwrite reports under (`owned` → `overwrite[]`, the other two → `merge[]`), and what happens when the release newly owns a path the adopter already has (`owned` backs up and overwrites, the other two fall through to the ordinary rows). Step 7 is authoritative.

Backups land in `.gaia-backup/<timestamp>/`. Conflict patches land in `.gaia-merge/`.

**Who runs what.** This file runs the pre-flight through Step 4b, spawns the execution agent for Steps 6 to 9 (`references/merge-execution.md`), runs Steps 9b to 10 itself once the agent returns, and then waits for the user. Once the user confirms the Step 10 commit, run Steps 11 and 12 below. Every orchestrator step lives in this one file, long as it is, because the merge walk can overwrite this skill's own files partway through the run and the orchestrator keeps following the copy it already read.

## Pre-flight: Worktree check

This wrapper changes `.gaia/VERSION` and opens a PR, both belong on the main checkout, not a per-SPEC worktree branch. If invoked from a linked worktree, reject hard with a message that surfaces the cached version state from main so the user knows whether a GAIA update is even pending.

Detection (run this first, before anything else):

```bash
. .gaia/scripts/main-only-lib.sh
gaia_update_gaia_state_line() {
  local cache_file="$1"
  [ -f "$cache_file" ] && command -v jq >/dev/null 2>&1 || return 0
  local gaia_current gaia_latest gaia_has_update
  gaia_current="$(jq -r '.gaiaCurrent // ""' "$cache_file" 2>/dev/null)"
  gaia_latest="$(jq -r '.gaiaLatest // ""' "$cache_file" 2>/dev/null)"
  gaia_has_update="$(jq -r '.gaiaHasUpdate // false' "$cache_file" 2>/dev/null)"
  [ -n "$gaia_current" ] && [ -n "$gaia_latest" ] || return 0
  local update_phrase="not-available"
  [ "$gaia_has_update" = "true" ] && update_phrase="available"
  printf 'Cached on main: GAIA %s installed; latest %s (update %s).\n' "$gaia_current" "$gaia_latest" "$update_phrase"
}
gaia_refuse_if_worktree "/update-gaia" gaia_update_gaia_state_line || exit 1
```

If the detection does not fire, fall through to the existing `## Pre-flight: Branch check` section.

## Pre-flight: Branch check

```bash
git branch --show-current
```

If the current branch is `main` or `master`, set a flag (`SHOULD_CREATE_BRANCH=true`) but **do not create the branch yet**, creation is deferred until after the Step 4 "Proceed" confirmation. Steps 1 to 4 can exit early (already up to date, a refused baseline, a failed Step 3c verification, a Step 3d stop, or the user aborts); branching before then leaves an orphan update branch when there was nothing to update.

Otherwise set `SHOULD_CREATE_BRANCH=false` and proceed on the current branch.

## Step 1: Read baseline version

```bash
cat .gaia/VERSION 2>/dev/null || echo MISSING
```

If the file is missing, stop and tell the user:

> "No `.gaia/VERSION` found, this project was not scaffolded from GAIA, or the marker was deleted. Run `/gaia-init` on a fresh `create-gaia` scaffold first."

Persist the trimmed version as `BASELINE` (e.g., `1.0.0`).

## Step 2: Resolve latest release

```bash
gh release list --repo gaia-react/gaia --limit 1 --json tagName --jq '.[0].tagName'
```

Persist as `LATEST_TAG` (e.g., `v1.0.1`) and `LATEST` (strip leading `v`).

If `gh` is unavailable, fall back to:

```bash
curl -fsSL https://api.github.com/repos/gaia-react/gaia/releases/latest | jq -r .tag_name
```

If both fail, stop and ask the user to supply the target version explicitly.

## Step 3: Compare versions

- If `LATEST == BASELINE`:
  - **First, detect an interrupted prior run.** If `.gaia/VERSION` differs from the last commit (`git diff --quiet HEAD -- .gaia/VERSION` exits non-zero, this catches a staged or unstaged bump), a previous `/update-gaia` already bumped the version but the update was never committed. Do **not** print "up to date", the bumped VERSION makes every re-run look current, so saying it dead-ends the user. Instead read the committed baseline (`git show HEAD:.gaia/VERSION`) for context and tell the user: the update to `v$LATEST` is already applied to the working tree but not committed. Review `git diff` and commit it (Step 10 guidance), or run `git checkout -- .gaia/VERSION` to discard the bump and re-run `/update-gaia` to start over. Exit.
  - Otherwise print "You are up to date on GAIA v$BASELINE." and exit.
- If `semver(LATEST) < semver(BASELINE)` → print a warning that the installed version is ahead of the latest release and exit. Never downgrade.
- If `LATEST` is above `BASELINE`, look for the update branch of an interrupted run to `$LATEST_TAG`, then continue to Step 3b:

```bash
RESUME_UPDATE=false
UPDATE_BRANCH=''
current_branch="$(git branch --show-current)"
case "$current_branch" in
  "update/${LATEST_TAG}-"*) UPDATE_BRANCH="$current_branch" ;;
  *) UPDATE_BRANCH="$(git for-each-ref --count=1 --sort=-committerdate --format='%(refname:short)' "refs/heads/update/${LATEST_TAG}-*")" ;;
esac
if [ -n "$UPDATE_BRANCH" ]; then
  RESUME_UPDATE=true
  echo "RESUME $UPDATE_BRANCH"
fi
echo "RESUME_UPDATE=$RESUME_UPDATE"
```

The branch is found by its `update/$LATEST_TAG-` prefix, never by minting its name again: a minted name carries the current minute, so it never equals the interrupted run's. The current branch wins when it carries the prefix; otherwise the most recently committed matching local branch does.

On `RESUME <branch>`, tell the user this is a merged-but-unbumped tree: a prior run to `$LATEST_TAG` stopped after its merge and before its `.gaia/VERSION` write, so this run resumes on that branch, keeps `.gaia-backup`, and repeats the merge, the after-merge notes and the setup drift through to the version write. Persist `RESUME_UPDATE` and, when it is `true`, `UPDATE_BRANCH`. A run started on a branch that is neither `main`/`master` nor the found update branch stays on its current branch at Step 4, as any run off `main` does.

## Step 3b: Refuse a 1.x baseline

GAIA 2.0.0 moved the React app into `frontend/`, and the 2.x release manifest is keyed on those paths. A three-way merge from a 1.x baseline would read every baseline app path as an upstream deletion and offer to delete the adopter's app, so a 1.x project migrates through the 2.0.0 migration note bundled in the checksum-verified v2.0.0 release, never through this command. Run this before any download and before the Step 4 prompt, so nothing has been fetched, created or pruned when it refuses:

```bash
BASELINE_MAJOR="${BASELINE%%.*}"
case "$BASELINE_MAJOR" in
  '' | *[!0-9]*)
    echo "REFUSED: .gaia/VERSION holds '$BASELINE', which is not a version. Fix .gaia/VERSION, then re-run /update-gaia."
    exit 1
    ;;
esac
if [ "$BASELINE_MAJOR" -lt 2 ]; then
  echo "REFUSED: this project is on GAIA $BASELINE. /update-gaia cannot cross the 2.0.0 layout change. Nothing was changed. This command downloads the v2.0.0 release, verifies its checksum, and extracts it:"
  cat <<'FETCH_COMMAND'
  mkdir -p .gaia/local/cache/shared/migrate-2/v2.0.0/tree && gh release download v2.0.0 --repo gaia-react/gaia --pattern 'gaia-bundle-v2.0.0.tar.gz*' --dir .gaia/local/cache/shared/migrate-2/v2.0.0 --clobber && sed 's|  |  .gaia/local/cache/shared/migrate-2/v2.0.0/|' .gaia/local/cache/shared/migrate-2/v2.0.0/gaia-bundle-v2.0.0.tar.gz.sha256 | shasum -a 256 -c - && tar -xzf .gaia/local/cache/shared/migrate-2/v2.0.0/gaia-bundle-v2.0.0.tar.gz -C .gaia/local/cache/shared/migrate-2/v2.0.0/tree --strip-components=1
FETCH_COMMAND
  echo "Once that command succeeds and the user agrees, follow .gaia/local/cache/shared/migrate-2/v2.0.0/tree/.gaia/migrations/2.0.0.md in this session."
  exit 1
fi
```

On `REFUSED`, stop and relay the message: no branch, no prune, no download. For a 1.x baseline, offer to run the printed command, and only after the user says yes run it and follow the note it extracts, in this session.

## Step 3c: Download and verify the bundles

Every bundle this run reads is verified against its release's `.sha256` asset in this run, before the Proceed question, and every tree it reads is extracted again from that verified tarball. Each tag's cache directory, `.gaia/local/cache/shared/update-gaia/<tag>/` (gitignored, shared across worktrees), holds `gaia-bundle-<tag>.tar.gz`, `gaia-bundle-<tag>.tar.gz.sha256` and `tree/`, and the target's directory also holds the `changelog-range.md` Step 4 saves. A cached tarball skips only the download, never the verification or the extract; there is no verified-marker file.

```bash
verify_checklist() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 -c - >/dev/null
  else
    sha256sum -c - >/dev/null
  fi
}
for tag in "v$BASELINE" "$LATEST_TAG"; do
  dir=".gaia/local/cache/shared/update-gaia/$tag"
  tarball="gaia-bundle-${tag}.tar.gz"
  # A cached directory with no checksum predates verification: a cache miss.
  if [ -d "$dir" ] && [ ! -f "$dir/$tarball.sha256" ]; then
    rm -rf "$dir"
  fi
  mkdir -p "$dir"
  if [ ! -f "$dir/$tarball" ] || [ ! -f "$dir/$tarball.sha256" ]; then
    if ! gh release download "$tag" --repo gaia-react/gaia \
      --pattern "gaia-bundle-${tag}.tar.gz" \
      --pattern "gaia-bundle-${tag}.tar.gz.sha256" \
      --dir "$dir" --clobber; then
      rm -rf "$dir"
      echo "FETCH_FAILED $tag"
      exit 1
    fi
  fi
  if [ ! -f "$dir/$tarball.sha256" ]; then
    rm -rf "$dir"
    echo "CHECKSUM_MISSING $tag"
    exit 1
  fi
  # The checklist must name this tarball and nothing else, so a checklist for
  # another file can never vouch for it. The sed rewrite points the bare file
  # name at the cache directory, so the check runs from the project root.
  if ! awk -v name="$tarball" 'NF == 2 && $2 == name { matched++ } END { exit !(NR == 1 && matched == 1) }' "$dir/$tarball.sha256" \
    || ! sed "s|  |  $dir/|" "$dir/$tarball.sha256" | verify_checklist; then
    rm -rf "$dir"
    echo "VERIFY_FAILED $tag"
    exit 1
  fi
  rm -rf "$dir/tree"
  mkdir -p "$dir/tree"
  if ! tar -xzf "$dir/$tarball" -C "$dir/tree" --strip-components=1; then
    rm -rf "$dir"
    echo "FETCH_FAILED $tag"
    exit 1
  fi
  echo "VERIFIED $tag"
done
echo "BASELINE_DIR=.gaia/local/cache/shared/update-gaia/v$BASELINE/tree"
echo "LATEST_DIR=.gaia/local/cache/shared/update-gaia/$LATEST_TAG/tree"
```

Persist `BASELINE_DIR` and `LATEST_DIR` as printed. Only the update cache changes before the Proceed question.

The asset is `gaia-bundle-<tag>.tar.gz` from 2.0.0 on; releases before 2.0.0 published `gaia-<tag>.tar.gz` and are out of reach on purpose (Step 3b refuses a 1.x baseline, and the different name is what makes a 1.6.1 `/update-gaia` fail at its fetch step, before it writes anything, instead of misreading the moved layout as deletions).

Each failure line names the tag and removes that tag's cache directory, so a re-run starts clean. On any of them, stop: nothing was branched, pruned or merged.

- `FETCH_FAILED $LATEST_TAG` or `CHECKSUM_MISSING $LATEST_TAG`: the latest release is unreachable (network, auth) or lacks an asset. Tell the user, then re-run once it is reachable.
- `FETCH_FAILED v$BASELINE` or `CHECKSUM_MISSING v$BASELINE`: the baseline bundle is unavailable (an older release, or one published without a checksum). The three-way merge cannot run without a baseline, so stop and explain that the adopter can cherry-pick changes by hand, comparing their project to the release.
- `VERIFY_FAILED <tag>`: the tarball does not match its release checksum. Never use it. Tell the user and re-run; a second mismatch on a fresh download is a damaged or tampered release, which the user reports upstream.

## Step 3d: Select migration notes

A release can ship migration notes, one per version, in its bundle. Select the ones this update crosses with the verified target bundle's own selector, never the project's working-tree copy, so a mode or key a later release adds is judged by that release's selector:

```bash
selection="$(bash "$LATEST_DIR/.gaia/scripts/select-migration-notes.sh" "$LATEST_DIR" "$BASELINE" "$LATEST" 2>&1)"
selection_status=$?
if [ "$selection_status" -ne 0 ]; then
  echo "NOTES_FAILED"
  printf '%s\n' "$selection"
  echo "Next step: the target release's migration notes are unreadable, and nothing was changed. Re-run /update-gaia once a fixed release is out, and report the lines above upstream."
  exit 1
fi
tab="$(printf '\t')"
while IFS="$tab" read -r note_version note_mode note_path; do
  [ -n "$note_version" ] || continue
  case "$note_mode" in
    after-merge) echo "AFTER_MERGE $note_version $note_path" ;;
    *)
      echo "BLOCKING $note_version $note_path"
      break
      ;;
  esac
done <<SELECTED
$selection
SELECTED
```

The block prints `AFTER_MERGE <version> <path>` for each after-merge note in version order up to the first blocking note, and `BLOCKING <version> <path>` for that first blocking note. A mode this skill does not know reads as blocking, so the note itself says how to follow it. After-merge notes above a blocking note are left for the next run. Each path is inside the verified bundle, `$LATEST_DIR/.gaia/migrations/<version>.md`.

- **`NOTES_FAILED`**: stop and relay the lines. Nothing was branched, pruned or merged.
- **No `BLOCKING` line**: persist the `AFTER_MERGE` lines (possibly none) and continue to Step 4.
- **`BLOCKING <version> <path>`**: stop here, before the Proceed question. Tell the user the update crosses a blocking migration note, name its path inside the verified bundle, and list each `AFTER_MERGE` note as a note to follow after the blocking note's merge step and before its version write. Then ask with `AskUserQuestion` whether to follow the blocking note in this session. On yes, read the note from that path and follow it: it owns the hop to its own version, including its own merge and its `.gaia/VERSION` and manifest write at that version, and the user re-runs `/update-gaia` afterwards for any later notes and the setup drift. On no, stop: nothing was branched, pruned or merged, `.gaia/VERSION` is unchanged, and only the verified update cache remains.

## Step 4: Show the release notes and confirm

Show the human the **full baseline-to-latest CHANGELOG range**, not just the single latest tag's GitHub body, an adopter several versions behind needs every intervening entry. Read GAIA's own `CHANGELOG.md` at `$LATEST_TAG` (a plain markdown file, fetched no-auth from the raw URL, with a `gh` fallback) and extract every `## [x.y.z]` section strictly newer than `$BASELINE` through `$LATEST`:

```bash
changelog="$(curl -fsSL "https://raw.githubusercontent.com/gaia-react/gaia/$LATEST_TAG/CHANGELOG.md" 2>/dev/null)"
if [ -z "$changelog" ] && command -v gh >/dev/null 2>&1; then
  changelog="$(gh api "repos/gaia-react/gaia/contents/CHANGELOG.md?ref=$LATEST_TAG" \
    -H "Accept: application/vnd.github.raw" 2>/dev/null)"
fi

range="$(printf '%s\n' "$changelog" | bash .gaia/scripts/changelog-range.sh "$BASELINE" "$LATEST")"
range_file=".gaia/local/cache/shared/update-gaia/$LATEST_TAG/changelog-range.md"

if [ -n "$range" ]; then
  printf '%s\n' "$range" | tee "$range_file"
else
  rm -f "$range_file"
  # Fetch failed (offline, private, missing file): fall back to the single-tag
  # GitHub release body so the gate still has context.
  gh release view "$LATEST_TAG" --repo gaia-react/gaia --json body --jq .body
fi
```

The script prints the contiguous block from `$LATEST` down to (but not including) `$BASELINE`, without the `[Unreleased]` block or the bottom link-reference list. The block also saves that range as `changelog-range.md` in the target's cache directory, beside `tree/`, for Step 9's documented adopter actions: the release bundle withholds `CHANGELOG.md`, so this fetch is the execution agent's only copy. A failed fetch removes the file, so Step 9 reports the range as unavailable rather than reading a stale one. Print the range to the user. When Step 3d printed `AFTER_MERGE` lines, name each `AFTER_MERGE` note (its version and its path) as a note this run follows after the merge. Then use `AskUserQuestion`:

- **Question**: "Update GAIA from v$BASELINE to $LATEST_TAG?"
- **Options**: `Proceed` / `Abort`.

On `Abort`, exit cleanly: nothing changes outside the verified update cache.

### Step 4, on Proceed: the update branch

```bash
current_branch="$(git branch --show-current)"
if [ "$RESUME_UPDATE" = true ] && [ "$current_branch" = "$UPDATE_BRANCH" ]; then
  echo "ON_UPDATE_BRANCH $UPDATE_BRANCH"
elif [ "$RESUME_UPDATE" = true ] && [ "$SHOULD_CREATE_BRANCH" = true ]; then
  git switch "$UPDATE_BRANCH" || { echo "SWITCH_FAILED $UPDATE_BRANCH"; exit 1; }
elif [ "$SHOULD_CREATE_BRANCH" = true ]; then
  git checkout -b "$(bash .gaia/scripts/branch-name-lib.sh name update "$LATEST_TAG")" || { echo "BRANCH_FAILED"; exit 1; }
fi
git branch --show-current
```

A resumed run lands on the interrupted run's update branch; a fresh run from `main`/`master` mints the update branch name only now, after `Proceed`; any other run stays on its current branch. On `SWITCH_FAILED` or `BRANCH_FAILED`, stop and relay git's message.

## Step 4b: Prune prior-run artifacts

Three gitignored directories accumulate across updates: `.gaia-backup/`, `.gaia/local/cache/shared/update-gaia/`, and `.gaia-merge/`. Prune the prior runs' leftovers here, at the start of a confirmed update and **before this run creates any of its own merge artifacts** (Step 7 creates `$BACKUP_DIR`), so the current run's fresh safety net is never touched. This runs only after the Step 4 `Proceed`, so an abort, an already-up-to-date exit, and the uncommitted-bump case Step 3 surfaces never reach it.

```bash
# .gaia-backup/: prior runs' pre-overwrite copies. Once an update is committed,
# git history is the durable recovery, so prior backups are redundant. A
# resumed run keeps them: they are the only copy of what the interrupted
# run's merge overwrote. This run creates its own $BACKUP_DIR in Step 7.
if [ "$RESUME_UPDATE" != true ]; then
  rm -rf .gaia-backup
fi

# .gaia/local/cache/shared/update-gaia/: keep the baseline and target
# directories Step 3c just verified and extracted, and delete every other
# cached tag dir. The loop only ever touches tag dirs here, update-check.json
# and serena-guard/ live one level up at shared/, structurally outside this
# glob.
if [ -d .gaia/local/cache/shared/update-gaia ]; then
  for d in .gaia/local/cache/shared/update-gaia/*/; do
    [ -d "$d" ] || continue
    case "$(basename "$d")" in
      "v$BASELINE" | "$LATEST_TAG") continue ;;
    esac
    rm -rf "$d"
  done
fi

# .gaia-merge/: conflict patches + .notes the operator resolves by hand (Step
# 11). Remove only when empty; a populated dir holds unresolved action items, so
# never delete it, warn and name the leftovers instead.
if [ -d .gaia-merge ]; then
  if [ -n "$(ls -A .gaia-merge 2>/dev/null)" ]; then
    echo "Heads up: .gaia-merge/ still holds unresolved patches from a prior run, NOT deleted:"
    ls -A .gaia-merge
    echo "Resolve or delete them by hand, then re-run /update-gaia."
  else
    rmdir .gaia-merge
  fi
fi
```

## Model selection

After the user confirms, determine the model for the execution agent:

- Compare `LATEST` major vs `BASELINE` major (leading integer).
- **Major bump** → spawn an **Opus agent** (`model: "opus"`).
- **Minor or patch bump** → spawn a **Sonnet agent** (`model: "sonnet"`).

Spawn the agent for Steps 6 to 9, passing `BASELINE`, `LATEST`, `LATEST_TAG`, `BASELINE_DIR` and `LATEST_DIR`. Its prompt tells it to read `.claude/skills/update-gaia/references/merge-execution.md` in full before starting Step 6 (in chunks if the Read tool refuses the size, but every chunk before Step 6) and follow it exactly. It must finish reading before Step 6 because the Step 7 walk can overwrite this skill's own files partway through the run, and the agent keeps executing the copy it read. The agent ends after its Step 9 summary and returns its `UpdateMergeReport`; relay the summary to the user, then continue with Step 9b.

## Step 9b: Follow the after-merge notes

For each `AFTER_MERGE` note Step 3d printed, in version order, read it from its path in the verified target bundle and follow it. A note may ask the user. After-merge notes are idempotent, so a resumed run repeats them safely. A note that cannot be completed stops the run here, with `.gaia/VERSION` still at the baseline, so the next run finds the update branch and resumes (Step 3).

## Step 9c: Carry new setup features

A release can list setup features an existing project has not decided yet. Compare the verified target bundle's feature list with this project's decision records, using the working-tree CLI the merge just updated:

```bash
drift_error_file="$(mktemp)"
if ! drift_json="$(.gaia/cli/gaia setup drift --json --features "$LATEST_DIR/.gaia/setup-features.json" 2>"$drift_error_file")" \
  || ! printf '%s' "$drift_json" | jq -e '.undecided | type == "array"' >/dev/null 2>&1; then
  drift_reason="$(head -n 1 "$drift_error_file")"
  rm -f "$drift_error_file"
  echo "DRIFT_FAILED ${drift_reason:-drift output unreadable}"
  exit 0
fi
rm -f "$drift_error_file"

# The admin probe runs once, and only when a project-scope admin feature is
# due to be applied or asked. No GitHub origin or a failed probe is not an admin.
is_admin=false
if printf '%s' "$drift_json" | jq -e 'any(.undecided[]; (.action == "apply" or .action == "ask") and .scope == "project" and .admin == true)' >/dev/null 2>&1; then
  remote_json="$(.gaia/cli/gaia setup detect-remote --json 2>/dev/null)" || remote_json=''
  remote_owner="$(printf '%s' "$remote_json" | jq -r 'select(.found == true and .host == "github.com") | .owner // empty' 2>/dev/null)"
  remote_repo="$(printf '%s' "$remote_json" | jq -r 'select(.found == true and .host == "github.com") | .repo // empty' 2>/dev/null)"
  if [ -n "$remote_owner" ] && [ -n "$remote_repo" ]; then
    admin_json="$(.gaia/cli/gaia setup check-admin --owner "$remote_owner" --repo "$remote_repo" --json 2>/dev/null)" || admin_json=''
    if printf '%s' "$admin_json" | jq -e '.admin == true and .auth_status == "ok"' >/dev/null 2>&1; then
      is_admin=true
    fi
  fi
fi

printf '%s' "$drift_json" | jq -r --argjson is_admin "$is_admin" '
  .undecided[]
  | if .action == "setup" then "SETUP \(.id)"
    elif .scope == "project" and .admin == true and ($is_admin | not) then "OWED_ADMIN \(.id)"
    elif .action == "apply" then "APPLY \(.id) \(.reference)"
    elif .action == "ask" then "ASK \(.id) \(.reference)"
    else "SETUP \(.id)"
    end'
```

Drift never fails an update: on `DRIFT_FAILED <reason>`, keep the reason for the Step 9d addendum and continue. Otherwise take each token in order:

- **`APPLY <id> <reference>`**: read the reference from the working tree and apply the feature with no question, then run `.gaia/cli/gaia setup record <id> applied`.
- **`ASK <id> <reference>`**: read the reference and ask the user once, then record the answer with `.gaia/cli/gaia setup record <id> <applied|declined|not-applicable>`. A dismissed question records nothing.
- **`OWED_ADMIN <id>`**: a project-scope feature that needs a repository admin, met by a non-admin. Neither apply, ask nor record it.
- **`SETUP <id>`**: the feature needs the full setup flow; name it as "run /setup-gaia". With no decision records at all, drift reports every listed id this way, so the whole set goes to `/setup-gaia`.

A failed apply records nothing, and neither does a `record` that refuses: name that id as failed, and the next run retries it. Project-scope records land in `.gaia/project.json` and ride the update commit; machine-scope records land in `.gaia/local/setup-state.json`.

## Step 9d: Record the update

The merge, the notes and the drift are done, so record the update. The order is the contract:

```bash
GAIA_MANIFEST_WRITE=release cp "$LATEST_DIR/.gaia/manifest.json" .gaia/manifest.json || { echo "MANIFEST_COPY_FAILED"; exit 1; }
.gaia/cli/gaia ping --event update --from "$BASELINE" --to "$LATEST" || true
echo "$LATEST" > .gaia/VERSION
```

`.gaia/VERSION` is written last. An interruption anywhere before that write leaves it at the baseline, so the next run finds the update branch and resumes (Step 3), repeating the idempotent merge, the after-merge notes and the drift. An interruption between the ping and the version write can repeat the ping on that re-run, which beats losing it. The ping records the version transition for adoption analytics and is best-effort; it never gates the update. On `MANIFEST_COPY_FAILED`, stop and relay it: the version stays at the baseline and a re-run resumes.

The manifest copy carries the `GAIA_MANIFEST_WRITE=` marker, a bare edit is blocked by `.claude/hooks/block-manifest-write.sh`, and this wholesale replace is the release-only write the guard exempts. This refreshes `.gaia/manifest.json` from the release copy so the next `/update-gaia` has the right baseline. Unresolved conflict patches, re-pin notes, or a migration action item do **not** block this bump, they are follow-ups the user resolves against the already-recorded update; `.gaia/VERSION` tracks the file merge, which is done.

Then bust the update-check cache so the SessionStart prompt reflects the post-update state on the next session. Use the Write tool to overwrite `.gaia/local/cache/shared/update-check.json`: read the existing cache first, then write it back unchanged **except** `gaiaCurrent` and `gaiaLatest` set to `$LATEST`, `gaiaHasUpdate` set to `false`, `outdatedCount` set to `0`, and `checkedAt` set to the current Unix timestamp. **Carry every other field across verbatim, named here or not.** The cache holds fields this step has no reason to know about, and several are observations nothing later can reconstruct (`cleanseMemoryBaseline`, the two `codify*` counts, and `codifyNudgeReason`), so dropping one silently disarms the nudge it belongs to instead of causing a visible error. If the cache file does not exist, skip this step.

The next SessionStart hook fires the background refresher; the session after that sees no GAIA update available.

Then print a summary addendum after the execution agent's table:

- each migration note followed, by version and path;
- the setup features applied, asked (with the answer), owed by an admin, failed, and handed to `/setup-gaia`, each by id, or the `DRIFT_FAILED` reason.

## Step 10: Next steps for the user

Tell the user:

1. Review any conflict patches in `.gaia-merge/` and reconcile manually. Delete the patch file once resolved. If `.gaia-merge/package.json.notes` or `.gaia-merge/pnpm-workspace.yaml.notes` exists, reconcile the re-pin conflicts and decide on the suggestions, then delete it.
2. If the `package.json` or `pnpm-workspace.yaml` merge applied any change, sync `pnpm-lock.yaml` before the quality gate, but pick the command by what changed. A dependency or `packageManager` bump syncs with `pnpm install`. An `overrides`, `allowBuilds`, or resolution-setting change needs `pnpm dedupe` instead: `pnpm install` short-circuits with "Already up to date" when only the `overrides:` map moved and leaves the lockfile untouched, so a floor you just accepted would be declared in config and unapplied in the tree, with nothing red to say so (`wiki/dependencies/pnpm-overrides.md`). `pnpm dedupe` is correct for both cases, so prefer it when unsure.
3. If any region regeneration failed, was refused, or was skipped, running the command named in the Step 9 report is a follow-up the adopter owns. Resolve whatever suppressed it first (the conflict patch for that path, most often), then run the command and re-run the roster check to confirm the region is current.
4. If Step 7e reported stale package settings, or you resolved a `.claude/settings.json` conflict patch, run `./.gaia/cli/gaia packages sync-settings` and then `bash .gaia/scripts/check-settings-drift.sh`, and stage the regenerated `frontend/.claude/settings.json`. Never hand-edit that file.
5. Run the quality gate per `wiki/decisions/Quality Gate.md` to verify the updated code still passes.
6. Inspect the diff (`git diff`) before committing. When Step 9c recorded a project decision, `.gaia/project.json` belongs in the commit.
7. When satisfied, commit with `chore(gaia): update to $LATEST_TAG`.

Do **not** auto-commit on behalf of the user, they need to review the changes first.

---

## Step 11 (orchestrator, after the user commits)

Step 11 runs in the **orchestrator**, not the spawned agent: it depends on the Step 10 commit, which is the user's manual action and lands after the one-shot agent has already returned. Run it once that commit exists.

### Step 11: Open a pull request

After the Step 10 commit lands, `/update-gaia` must not leave the branch stranded, open a PR so the update can be reviewed and merged.

The orchestrator waits for the user to confirm the Step 10 commit landed before pushing, the `git rev-list` guard below is only a backstop for the empty-branch case, not a replacement for that confirmation.

Push the branch and open a PR, but only if it has no open PR already, a re-run of `/update-gaia` on the same branch updates the existing PR instead of duplicating it:

```bash
branch="$(git branch --show-current)"

# The update must be committed first (Step 10). No commits ahead of main → finish Step 10.
if [ "$(git rev-list --count main.."$branch" 2>/dev/null || echo 0)" -eq 0 ]; then
  echo "Nothing committed ahead of main, commit the update (Step 10) before opening a PR."
  exit 0
elif ! git push -u origin "$branch"; then
  echo "Push failed, resolve the push error, then open the PR manually: $branch → main."
else
  existing="$(gh pr list --head "$branch" --state open --json number --jq '.[0].number // empty' 2>/dev/null)"
  if [ -n "$existing" ]; then
    echo "PR #$existing already open for $branch, pushed the new commit to it."
  else
    gh pr create --draft --base main --head "$branch" \
      --title "chore(gaia): update to $LATEST_TAG" \
      --body "Pulls GAIA $LATEST_TAG into the project. Per-file outcomes are in the update summary above."
  fi
fi
```

If `gh` is unavailable or errors, tell the user to open the PR manually: `$branch` → `main`.

### Step 12: Offer the residue sweep

The merged `.gaia/state-registry.json` names the `.gaia/local` state that retired features left behind. Run `bash .gaia/scripts/state-registry-lib.sh residue-sweep` and show its output. When its Residue section lists paths, ask once with `AskUserQuestion` (question `Delete the residue paths listed above?`, header `Residue`, options `Delete them` and `Keep them`) and on `Delete them` run the same command with `--apply`. It deletes only the Residue paths; Unknown paths are listed, never deleted. A non-zero exit names its cause on stderr: relay it and finish, since the update itself is done.
