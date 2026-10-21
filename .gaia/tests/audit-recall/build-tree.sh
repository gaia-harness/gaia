#!/usr/bin/env bash
# build-tree.sh: build the replay tree for one real recall entry.
#
#   build-tree.sh --repo <maintainer checkout> --bundle <sha> --base <sha> --head <sha> --clone <dir>
#
# 1. <dir> comes from the measurement toolkit's prepare-scratch-clone.sh at
#    <base>: a standalone clone, never a linked worktree (a linked worktree's
#    .gaia/local is a symlink into the live audit store, so replay markers,
#    sidecars and loop state would land there), marker-stripped, sentinel
#    written. The toolkit's README says why the marker goes.
# 2. On the clone's `main`, the bundle's harness replaces the base's:
#    .claude, .github/audit, wiki, frontend/.claude and .gaia (never
#    .gaia/local, which is untracked) are removed and checked out from the
#    bundle commit, so a file the bundle deleted does not linger as a stale
#    rule or agent definition. frontend/.claude holds the frontend member's
#    extension rules. The maintainer marker is deleted again when the bundle
#    restored it, and the result is committed as the replay's `main`.
# 3. The change under review, `git diff <base> <head>` minus the marker path,
#    is applied with `git apply --3way` on a `replay` branch cut from that
#    `main` and committed.
# 4. origin/main is pointed at the replay `main` and the replay branch's
#    audit-base cache names `main`, so every member resolves its review base to
#    the replay `main` without asking gh; the bundle's resolve-audit-base.sh is
#    run in the clone to prove it.
#
# The source checkout is only read (clone and fetch from it); nothing is
# written outside <dir>.
#
# Exit 0 built (the clone is left on `replay`), 2 usage, 4 the change
# conflicts with the bundle overlay, 5 the base does not resolve, 6 the bundle
# does not resolve, 7 the head does not resolve, 8 the resolved review base is
# not the replay `main`, 1 any other git failure. Every failure's last stderr
# line is `build-tree: failed: <reason token>`, which select.mjs records.
set -euo pipefail

SCRIPT_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PREPARE_SCRATCH_CLONE="$SCRIPT_DIRECTORY/../audit-cost/prepare-scratch-clone.sh"
MARKER_PATH=".claude/rules/maintainers/harness-triage-threshold.md"
HARNESS_PATHS=(.claude .github/audit wiki frontend/.claude .gaia)

usage() {
  echo "usage: build-tree.sh --repo <maintainer checkout> --bundle <sha> --base <sha> --head <sha> --clone <dir>" >&2
}

fail() {
  local status="$1" token="$2"
  shift 2
  [ "$#" -eq 0 ] || echo "build-tree: $*" >&2
  echo "build-tree: failed: $token" >&2
  exit "$status"
}

repo=""
bundle=""
base=""
head=""
clone=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo | --bundle | --base | --head | --clone)
      [ "$#" -ge 2 ] && [ -n "$2" ] || { usage; exit 2; }
      case "$1" in
        --repo) repo="$2" ;;
        --bundle) bundle="$2" ;;
        --base) base="$2" ;;
        --head) head="$2" ;;
        --clone) clone="$2" ;;
      esac
      shift 2
      ;;
    *)
      usage
      exit 2
      ;;
  esac
done
{ [ -n "$repo" ] && [ -n "$bundle" ] && [ -n "$base" ] && [ -n "$head" ] && [ -n "$clone" ]; } || { usage; exit 2; }
git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 || { echo "build-tree: --repo is not a git repository: $repo" >&2; exit 2; }

resolve_in_source() {
  git -C "$repo" rev-parse --verify --quiet "$1^{commit}" 2>/dev/null
}
base_sha="$(resolve_in_source "$base")" || fail 5 base-unresolvable "base $base is not a commit in $repo"
bundle_sha="$(resolve_in_source "$bundle")" || fail 6 bundle-unresolvable "bundle $bundle is not a commit in $repo"
head_sha="$(resolve_in_source "$head")" || fail 7 head-unresolvable "head $head is not a commit in $repo"

bash "$PREPARE_SCRATCH_CLONE" --source "$repo" --ref "$base_sha" --out "$clone" >/dev/null || fail 1 clone-failed "prepare-scratch-clone.sh failed for $base_sha"

in_clone() {
  git -C "$clone" -c user.name=measurement -c user.email=measurement@example.com -c commit.gpgsign=false "$@"
}

# A clone copies only the source's branches; a bundle or head that only a
# remote-tracking ref or a detached worktree reaches is fetched by sha.
for commit in "$bundle_sha" "$head_sha"; do
  if ! git -C "$clone" cat-file -e "$commit^{commit}" 2>/dev/null; then
    git -C "$clone" fetch --quiet --no-tags "$repo" "$commit" || fail 1 fetch-failed "cannot fetch $commit from $repo"
  fi
done

in_clone checkout --quiet main
in_clone rm -r -q --ignore-unmatch -- ${HARNESS_PATHS[@]+"${HARNESS_PATHS[@]}"} || fail 1 overlay-failed "cannot remove the base harness"
present_paths=()
for harness_path in ${HARNESS_PATHS[@]+"${HARNESS_PATHS[@]}"}; do
  [ -z "$(git -C "$clone" ls-tree --name-only "$bundle_sha" -- "$harness_path")" ] || present_paths+=("$harness_path")
done
[ "${#present_paths[@]}" -eq 0 ] || in_clone checkout "$bundle_sha" -- "${present_paths[@]}" || fail 1 overlay-failed "cannot check the bundle harness out"
if [ -e "$clone/$MARKER_PATH" ]; then
  in_clone rm -q --cached --ignore-unmatch -- "$MARKER_PATH"
  rm -f "$clone/$MARKER_PATH"
fi
in_clone commit --quiet --no-verify --allow-empty -m "replay: harness overlay from bundle $bundle_sha" || fail 1 overlay-failed "cannot commit the overlay"
replay_main="$(git -C "$clone" rev-parse HEAD)"

in_clone checkout --quiet -b replay
patch_file="$clone/.git/recall-change.patch"
git -C "$clone" diff --binary --no-renames "$base_sha" "$head_sha" -- . ":(exclude)$MARKER_PATH" >"$patch_file"
if [ -s "$patch_file" ]; then
  in_clone apply --3way --index --whitespace=nowarn "$patch_file" >/dev/null 2>&1 ||
    fail 4 patch-conflicts-overlay "the change $base_sha..$head_sha does not apply over bundle $bundle_sha"
fi
in_clone commit --quiet --no-verify --allow-empty -m "replay: the change under review ($head_sha)" || fail 1 replay-commit-failed "cannot commit the replayed change"

git -C "$clone" update-ref refs/remotes/origin/main "$replay_main"
git -C "$clone" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
git -C "$clone" config branch.replay.gaia-audit-base main

resolver="$clone/.github/audit/resolve-audit-base.sh"
[ -f "$resolver" ] || fail 8 base-mismatch "the bundle carries no .github/audit/resolve-audit-base.sh"
resolved_base="$(cd "$clone" && env -u GH_TOKEN -u GITHUB_TOKEN -u GITHUB_REPOSITORY bash "$resolver" 2>/dev/null </dev/null | head -n 1)" || resolved_base=""
resolved_commit="$(git -C "$clone" rev-parse --verify --quiet "${resolved_base:-none}^{commit}" 2>/dev/null)" || resolved_commit=""
[ "$resolved_commit" = "$replay_main" ] ||
  fail 8 base-mismatch "resolve-audit-base.sh answered '${resolved_base:-nothing}', not the replay main $replay_main"

printf '%s\n' "$clone"
