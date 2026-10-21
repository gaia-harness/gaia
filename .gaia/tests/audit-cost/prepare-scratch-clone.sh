#!/usr/bin/env bash
# prepare-scratch-clone.sh: the one way a measurement or recall run gets a
# maintainer tree.
#
#   prepare-scratch-clone.sh --source <repo> --ref <sha|branch> --out <dir>
#
# Builds <dir> as a standalone clone of <source> (git clone --no-hardlinks, so
# it shares no object file with the source), checks <ref> out as the clone's
# local `main`, removes the maintainer marker
# .claude/rules/maintainers/harness-triage-threshold.md and commits the removal
# on that `main`, cuts the throwaway branch scratch-<epoch> from it, and writes
# the sentinel <dir>/.gaia/local/measurement-scratch that the probe, replay and
# recall runners require.
#
# Why the marker is stripped. In a tree carrying it, audit-loop-bound.sh
# refuses the first member or unit dispatch until verify-harness.sh branch has
# passed for that HEAD, a multi-minute run per replay HEAD that historical trees
# are likely to fail; that gate guards the maintainer's own merges, not a
# measurement. Removing it also turns off the maintainer-only branches of
# audit-light-telemetry.sh and audit-loop-eval.sh and removes one rule file
# from a member's project instructions, none of which changes what a member
# reviews. Before and after clones get the identical treatment, so the
# comparison stays like for like.
#
# The clone is its own repository: its git common dir is its own .git, never a
# linked worktree of the source, so no run touches the source's refs, working
# tree or audit-loop state. Its origin push URL is disabled.
#
# Exit 0 on success, 2 on a usage error or an --out that exists and is not
# empty, 1 on a git failure.
set -euo pipefail

MARKER_PATH=".claude/rules/maintainers/harness-triage-threshold.md"

usage() {
  echo "usage: prepare-scratch-clone.sh --source <repo> --ref <sha|branch> --out <dir>" >&2
}

refuse() {
  echo "ERROR: $*" >&2
  exit 2
}

source_repo=""
reference=""
output_directory=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --source | --ref | --out)
      [ "$#" -ge 2 ] && [ -n "$2" ] || { usage; exit 2; }
      case "$1" in
        --source) source_repo="$2" ;;
        --ref) reference="$2" ;;
        --out) output_directory="$2" ;;
      esac
      shift 2
      ;;
    *)
      usage
      exit 2
      ;;
  esac
done
{ [ -n "$source_repo" ] && [ -n "$reference" ] && [ -n "$output_directory" ]; } || { usage; exit 2; }

git -C "$source_repo" rev-parse --git-dir >/dev/null 2>&1 || refuse "--source is not a git repository: $source_repo"
if [ -e "$output_directory" ] && [ -n "$(ls -A "$output_directory" 2>/dev/null)" ]; then
  refuse "--out exists and is not empty: $output_directory"
fi
commit="$(git -C "$source_repo" rev-parse --verify --quiet "$reference^{commit}")" || refuse "--ref does not resolve in the source: $reference"

git clone --quiet --no-hardlinks "$source_repo" "$output_directory"
if ! git -C "$output_directory" cat-file -e "$commit^{commit}" 2>/dev/null; then
  # A commit no branch of the source reaches (a detached worktree HEAD).
  git -C "$output_directory" fetch --quiet --no-tags "$source_repo" "$commit"
fi
git -C "$output_directory" checkout --quiet -B main "$commit"
git -C "$output_directory" remote set-url --push origin no-push-from-a-measurement-clone

if [ -e "$output_directory/$MARKER_PATH" ]; then
  git -C "$output_directory" rm --quiet -- "$MARKER_PATH"
  git -C "$output_directory" -c user.name=measurement -c user.email=measurement@example.com -c commit.gpgsign=false \
    commit --quiet --no-verify -m "scratch: remove the maintainer marker for a measurement run"
fi

epoch="$(date +%s)"
git -C "$output_directory" checkout --quiet -b "scratch-$epoch"

mkdir -p "$output_directory/.gaia/local"
printf 'measurement scratch clone of %s at %s, created %s\n' "$source_repo" "$commit" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$output_directory/.gaia/local/measurement-scratch"
printf '%s\n' "$output_directory"
