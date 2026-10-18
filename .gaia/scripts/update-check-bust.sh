#!/usr/bin/env bash
# shellcheck shell=bash
#
# update-check-bust.sh: rewrite the statusline's update-check cache after an
# update run, so the statusline shows the post-run state instead of a stale
# "updates available". Run it by any path that resolves; the spelling below
# assumes a shell at the checkout root:
#   bash .gaia/scripts/update-check-bust.sh --cache <absolute path> --mode deps
#   bash .gaia/scripts/update-check-bust.sh --cache <absolute path> --mode gaia --version <x.y.z>
#   bash .gaia/scripts/update-check-bust.sh --cache <absolute path> --mode gaia --version <x.y.z> --drop-claim <number>
#
# `deps` sets outdatedCount to 0 and checkedAt to now. `gaia` sets gaiaCurrent
# and gaiaLatest to the version, gaiaHasUpdate to false, outdatedCount to 0 and
# checkedAt to now. checkedAt is integer Unix seconds.
#
# EVERY OTHER FIELD CARRIES ACROSS UNCHANGED, named above or not. The cache
# holds observations nothing can reconstruct (cleanseMemoryBaseline, the
# codify* fields), so a rewrite that dropped a field it did not know would
# destroy them. The edit is a merge into the parsed object, never a rebuild.
#
# Exit codes, with a status line on stdout:
#   0   BUSTED               the cache was rewritten
#   0   SKIPPED no cache     the file is absent; nothing is created
#   3   BUST_FAILED <reason> no jq, the JSON does not parse, or the write failed;
#                            the original file is left as it was. A failed bust
#                            is cosmetic, so the calling run continues.
#   2   a usage error
#
# WHY A SCRIPT. From inside a linked worktree the `.gaia/local` symlink
# resolves into the main checkout, where the Write tool is refused and a
# captured substitution such as `$(date +%s)` is refused too. A literal-path
# script given the main checkout's absolute path as an argument is the one
# shape that works from both trees.
#
# The new content is written to a temp file in the cache's own directory and
# moved over the cache, so a reader never sees a partial file and the move
# never crosses a filesystem.
#
# Bash 3.2 compatible. Never `cd`.

set -uo pipefail

PROGRAM_NAME="update-check-bust.sh"

usage() {
  cat <<EOF
Usage: bash .gaia/scripts/$PROGRAM_NAME --cache <absolute path> --mode deps
       bash .gaia/scripts/$PROGRAM_NAME --cache <absolute path> --mode gaia --version <x.y.z> [--drop-claim <number>]

  --cache    the update-check cache file. Required, absolute.
  --mode     deps or gaia. Required.
  --version  the version the run landed on. Required with --mode gaia.
  --drop-claim  a pull request number whose claim entry is removed. Digits only; --mode gaia only.

Prints BUSTED, SKIPPED no cache, or BUST_FAILED <reason>. Exit 2 is a usage error.
EOF
}

CACHE=""
MODE=""
VERSION=""
DROP_CLAIM=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --cache)
      [ "$#" -ge 2 ] || { printf '%s: --cache needs a value\n' "$PROGRAM_NAME" >&2; exit 2; }
      CACHE="$2"
      shift 2
      ;;
    --mode)
      [ "$#" -ge 2 ] || { printf '%s: --mode needs a value\n' "$PROGRAM_NAME" >&2; exit 2; }
      MODE="$2"
      shift 2
      ;;
    --version)
      [ "$#" -ge 2 ] || { printf '%s: --version needs a value\n' "$PROGRAM_NAME" >&2; exit 2; }
      VERSION="$2"
      shift 2
      ;;
    --drop-claim)
      [ "$#" -ge 2 ] || { printf '%s: --drop-claim needs a value\n' "$PROGRAM_NAME" >&2; exit 2; }
      DROP_CLAIM="$2"
      shift 2
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      printf '%s: unknown argument: %s\n' "$PROGRAM_NAME" "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

case "$CACHE" in
  /*) ;;
  *)
    printf '%s: --cache must be an absolute path, got: %s\n' "$PROGRAM_NAME" "$CACHE" >&2
    usage >&2
    exit 2
    ;;
esac

if [ -n "$DROP_CLAIM" ]; then
  case "$DROP_CLAIM" in
    *[!0-9]*)
      printf '%s: --drop-claim must be digits only, got: %s\n' "$PROGRAM_NAME" "$DROP_CLAIM" >&2
      exit 2
      ;;
  esac
  if [ "$MODE" != "gaia" ]; then
    printf '%s: --drop-claim is valid only with --mode gaia\n' "$PROGRAM_NAME" >&2
    exit 2
  fi
fi

case "$MODE" in
  deps) ;;
  gaia)
    if [ -z "$VERSION" ]; then
      printf '%s: --mode gaia needs --version\n' "$PROGRAM_NAME" >&2
      exit 2
    fi
    case "$VERSION" in
      *[!0-9A-Za-z.+-]*)
        printf '%s: --version has characters a version cannot: %s\n' "$PROGRAM_NAME" "$VERSION" >&2
        exit 2
        ;;
    esac
    ;;
  *)
    printf '%s: --mode must be deps or gaia, got: %s\n' "$PROGRAM_NAME" "$MODE" >&2
    usage >&2
    exit 2
    ;;
esac

if [ ! -f "$CACHE" ]; then
  printf 'SKIPPED no cache\n'
  exit 0
fi

if ! command -v jq >/dev/null 2>&1; then
  printf 'BUST_FAILED jq is not installed\n'
  exit 3
fi

# The jq programs name jq variables ($now, $version, $drop), not shell ones.
# shellcheck disable=SC2016
case "$MODE" in
  deps)
    jq_program='if type == "object" then .outdatedCount = 0 | .checkedAt = ($now | tonumber) else error("not an object") end'
    ;;
  gaia)
    jq_program='if type == "object" then .gaiaCurrent = $version | .gaiaLatest = $version | .gaiaHasUpdate = false | .outdatedCount = 0 | .checkedAt = ($now | tonumber) | (if $drop != "" and (.gaiaUpdateClaims | type) == "array" then .gaiaUpdateClaims |= map(select((.number | tostring) != $drop)) else . end) else error("not an object") end'
    ;;
esac

cache_directory="${CACHE%/*}"
[ -n "$cache_directory" ] || cache_directory="/"
now="$(date +%s)"

if ! temporary_file="$(mktemp "$cache_directory/.update-check-bust.XXXXXX" 2>/dev/null)"; then
  printf 'BUST_FAILED cannot create a temp file in %s\n' "$cache_directory"
  exit 3
fi

if ! jq --arg now "$now" --arg version "$VERSION" --arg drop "$DROP_CLAIM" "$jq_program" "$CACHE" >"$temporary_file" 2>/dev/null; then
  rm -f "$temporary_file"
  printf 'BUST_FAILED cache is not a JSON object jq can read\n'
  exit 3
fi

if ! mv -f "$temporary_file" "$CACHE" 2>/dev/null; then
  rm -f "$temporary_file"
  printf 'BUST_FAILED cannot replace %s\n' "$CACHE"
  exit 3
fi

printf 'BUSTED\n'
exit 0
