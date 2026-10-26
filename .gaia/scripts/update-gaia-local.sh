#!/usr/bin/env bash
# shellcheck shell=bash
#
# update-gaia-local.sh: the local-bundle steps of /update-gaia as plain
# subcommands, run with the working directory at the checkout root (the main
# checkout, or the update worktree). Every path stays repo-relative.
#   bash .gaia/scripts/update-gaia-local.sh source       --tarball <path> [--resume]
#   bash .gaia/scripts/update-gaia-local.sh baseline
#   bash .gaia/scripts/update-gaia-local.sh notes-not-run --latest-dir <dir> --core <x.y.z>
#
# source validates a bundle tarball the maintainer built from an unreleased
# checkout and places it in the update cache under its dev tag, so the later
# verify, merge and prune steps find it like a release bundle. Every refusal
# removes its scratch directory and leaves no new cache entry. The checksum
# next to the tarball, when present, guards against corruption only: nothing
# here proves who built the bundle, so the success line says `unverified`.
# --resume skips only the already-synced check, for a re-run inside an update
# branch whose record step already wrote the target build.
# baseline names the bundle the project's copy descends from: its recorded
# local build when still cached, else the plain release.
# notes-not-run lists the migration notes the bundle carries above its release
# version, which are followed by hand and never run.
#
# Exit codes: 0 success; 1 the step's own refusal or failure (its token is
# printed on stdout); 2 a usage error, with the usage on stderr.
#
# WHY A SCRIPT. Inside a linked worktree session the Claude Code runtime
# refuses a command it cannot verify stays inside the worktree: a captured
# command substitution, a shell variable interpolated into a path, a heredoc.
# These steps are full of all three, so each one runs here as one plain
# literal-path call.

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$script_directory/update-gaia-local-lib.sh"

usage() {
  cat >&2 <<'USAGE'
usage: update-gaia-local.sh source        --tarball <path> [--resume]
       update-gaia-local.sh baseline
       update-gaia-local.sh notes-not-run --latest-dir <dir> --core <x.y.z>
USAGE
  exit 2
}

version_pattern='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'
scratch_directory=''

cleanup_scratch() {
  [ -z "$scratch_directory" ] || rm -rf "$scratch_directory"
}

# Prints a refusal line and its next step, then exits 1. The trap removes the
# scratch directory.
refuse() {
  echo "LOCAL_REFUSED $1"
  echo "Next step: $2"
  exit 1
}

# A version file's content with surrounding whitespace removed; empty when
# unreadable.
trimmed_file() {
  local content
  content="$(cat "$1" 2>/dev/null)" || return 0
  content="${content#"${content%%[![:space:]]*}"}"
  content="${content%"${content##*[![:space:]]}"}"
  printf '%s\n' "$content"
}

# Writes the cache entry for the tag from tarball $2 (hash $3) and prints
# nothing. A directory with the same tarball bytes is reused; different bytes
# are a conflict; a directory with no tarball is replaced whole.
write_cache() {
  local tag="$1" tarball="$2" hash="$3" directory name existing_hash extract_word
  directory="$GAIA_UPDATE_CACHE_ROOT/$tag"
  name="gaia-bundle-${tag}.tar.gz"
  if [ -f "$directory/$name" ]; then
    existing_hash="$(gaia_local_sha256 "$directory/$name")"
    if [ "$existing_hash" != "$hash" ]; then
      refuse "cache-conflict $tag" "the cache already holds a different build for $tag. Nothing was changed. Rebuild from a new commit, or remove $directory yourself, then re-run /update-gaia --local."
    fi
  else
    rm -rf "$directory"
    mkdir -p "$directory" || refuse "unsafe-entry extract-failed" "the update cache could not be written. Nothing was changed."
    cp "$tarball" "$directory/$name" || refuse "unsafe-entry extract-failed" "the update cache could not be written. Nothing was changed."
  fi
  printf '%s  %s\n' "$hash" "$name" > "$directory/$name.sha256"
  rm -rf "$directory/tree"
  if ! extract_word="$(gaia_local_safe_extract "$directory/$name" "$directory/tree")"; then
    rm -rf "$directory"
    refuse "unsafe-entry $extract_word" "the bundle could not be extracted into the update cache. Nothing was changed."
  fi
}

run_source() {
  local tarball_argument="$1" resume="$2" tarball sibling hash bundle_directory
  local bundle_core bundle_build project_core project_build tag status_code extract_word

  case "$tarball_argument" in
    /*) tarball="$tarball_argument" ;;
    *) tarball="$PWD/$tarball_argument" ;;
  esac
  if [ ! -f "$tarball" ] || [ ! -r "$tarball" ]; then
    refuse tarball-unreadable "pass the path of a readable bundle tarball built by the local bundle builder. Nothing was changed."
  fi
  hash="$(gaia_local_sha256 "$tarball")"
  sibling="$tarball.sha256"
  if [ -f "$sibling" ]; then
    if ! awk -v name="${tarball##*/}" 'NF == 2 && $2 == name { matched++ } END { exit !(NR == 1 && matched == 1) }' "$sibling" \
      || [ "$(awk '{ print $1 }' "$sibling")" != "$hash" ]; then
      refuse checksum-mismatch "the checksum file beside the tarball does not match it. Rebuild the bundle, then re-run /update-gaia --local. Nothing was changed."
    fi
  fi

  scratch_directory="$(mktemp -d "${TMPDIR:-/tmp}/gaia-local.XXXXXX")" || refuse tarball-unreadable "no scratch directory could be created. Nothing was changed."
  trap cleanup_scratch EXIT
  bundle_directory="$scratch_directory/bundle"
  if ! extract_word="$(gaia_local_safe_extract "$tarball" "$bundle_directory")"; then
    refuse "unsafe-entry $extract_word" "the tarball is not a bundle this command accepts. Rebuild it with the local bundle builder. Nothing was changed."
  fi

  bundle_core="$(trimmed_file "$bundle_directory/.gaia/VERSION")"
  [[ "$bundle_core" =~ $version_pattern ]] || refuse version-malformed "the bundle's .gaia/VERSION is not a plain x.y.z. Rebuild the bundle. Nothing was changed."
  gaia_local_read_build_file "$bundle_directory/.gaia/VERSION-dev" > "$scratch_directory/build"
  status_code=$?
  case "$status_code" in
    0) bundle_build="$(cat "$scratch_directory/build")" ;;
    1) refuse build-id-missing "the bundle has no .gaia/VERSION-dev, so it is not a local build. Rebuild it with the local bundle builder. Nothing was changed." ;;
    *) refuse build-id-malformed "the bundle's .gaia/VERSION-dev is not a build id. Rebuild the bundle. Nothing was changed." ;;
  esac
  [ -f "$bundle_directory/.gaia/manifest.json" ] || refuse manifest-missing "the bundle has no .gaia/manifest.json. Rebuild the bundle. Nothing was changed."

  project_core="$(trimmed_file .gaia/VERSION)"
  [[ "$project_core" =~ $version_pattern ]] || refuse project-version-malformed "fix .gaia/VERSION in this project, then re-run /update-gaia --local. Nothing was changed."
  project_build=''
  gaia_local_read_build_file .gaia/VERSION-dev > "$scratch_directory/project-build"
  status_code=$?
  case "$status_code" in
    0) project_build="$(cat "$scratch_directory/project-build")" ;;
    1) ;;
    *) refuse project-build-malformed "fix or delete .gaia/VERSION-dev in this project and commit it, then re-run /update-gaia --local. Nothing was changed." ;;
  esac

  if gaia_local_version_below "$bundle_core" "$project_core"; then
    refuse "older-than-project $bundle_core $project_core" "this project is already on a newer GAIA than the bundle. Build the bundle from a newer checkout. Nothing was changed."
  fi
  if [ "$resume" != true ] && [ "$bundle_build" = "$project_build" ]; then
    echo "ALREADY_SYNCED $bundle_build"
    return 0
  fi

  tag="$(gaia_local_tag_for "$bundle_core" "$bundle_build")"
  write_cache "$tag" "$tarball" "$hash"
  echo "LOCAL_SOURCE unverified"
  echo "LOCAL_TAG=$tag"
  echo "LOCAL_CORE=$bundle_core"
  echo "LOCAL_BUILD=$bundle_build"
  echo "LOCAL_COMMIT=${bundle_build#dev.}"
  echo "LATEST_DIR=$GAIA_UPDATE_CACHE_ROOT/$tag/tree"
}

# True when the cache holds a complete entry (tarball and checksum) for $1.
cache_has_entry() {
  [ -f "$GAIA_UPDATE_CACHE_ROOT/$1/gaia-bundle-$1.tar.gz" ] && [ -f "$GAIA_UPDATE_CACHE_ROOT/$1/gaia-bundle-$1.tar.gz.sha256" ]
}

run_baseline() {
  local version build status_code candidate other_core
  version="$(trimmed_file .gaia/VERSION)"
  if ! [[ "$version" =~ $version_pattern ]]; then
    echo "VERSION_INVALID .gaia/VERSION"
    echo "Next step: fix .gaia/VERSION so it holds a plain x.y.z, commit it, then re-run /update-gaia."
    exit 1
  fi
  build="$(gaia_local_read_build_file .gaia/VERSION-dev)"
  status_code=$?
  case "$status_code" in
    1)
      echo "BASELINE_TAG=v$version"
      return 0
      ;;
    2)
      echo "BUILD_ID_INVALID .gaia/VERSION-dev"
      echo "Next step: fix or delete .gaia/VERSION-dev and commit the change, then re-run /update-gaia."
      exit 1
      ;;
  esac
  if cache_has_entry "v$version-$build"; then
    echo "BASELINE_TAG=v$version-$build"
    echo "RECORDED_BUILD $build"
    return 0
  fi
  for candidate in "$GAIA_UPDATE_CACHE_ROOT"/v*-"$build"; do
    [ -d "$candidate" ] || continue
    other_core="${candidate##*/v}"
    other_core="${other_core%-"$build"}"
    [[ "$other_core" =~ $version_pattern ]] || continue
    [ "$other_core" != "$version" ] || continue
    cache_has_entry "v$other_core-$build" || continue
    echo "BASELINE_TAG=v$version"
    echo "RECORDED_BUILD_STALE $build $other_core"
    return 0
  done
  echo "BASELINE_TAG=v$version"
  echo "BASELINE_FALLBACK $build"
}

run_notes_not_run() {
  local latest_directory="$1" core="$2" selection tab note_version note_mode note_path
  if ! selection="$(bash "$latest_directory/.gaia/scripts/select-migration-notes.sh" "$latest_directory" "$core" 999999999.999999999.999999999 2>&1)"; then
    echo "NOTES_FAILED"
    printf '%s\n' "$selection"
    echo "Next step: the bundle's migration notes are unreadable. Rebuild the bundle from a fixed checkout, and nothing was changed."
    exit 1
  fi
  tab="$(printf '\t')"
  while IFS="$tab" read -r note_version note_mode note_path; do
    [ -n "$note_version" ] || continue
    echo "NOT_RUN $note_version $note_mode $note_path"
  done <<SELECTED
$selection
SELECTED
}

[ "$#" -ge 1 ] || usage
subcommand="$1"
shift

tarball_argument=''
latest_directory=''
core=''
resume=false
while [ "$#" -gt 0 ]; do
  case "$1" in
    --tarball | --latest-dir | --core)
      [ "$#" -ge 2 ] || usage
      case "$1" in
        --tarball) tarball_argument="$2" ;;
        --latest-dir) latest_directory="$2" ;;
        --core) core="$2" ;;
      esac
      shift 2
      ;;
    --resume)
      resume=true
      shift
      ;;
    *) usage ;;
  esac
done

case "$subcommand" in
  source)
    [ -n "$tarball_argument" ] || usage
    run_source "$tarball_argument" "$resume"
    ;;
  baseline) run_baseline ;;
  notes-not-run)
    [ -n "$latest_directory" ] && [[ "$core" =~ $version_pattern ]] || usage
    run_notes_not_run "$latest_directory" "$core"
    ;;
  *) usage ;;
esac
