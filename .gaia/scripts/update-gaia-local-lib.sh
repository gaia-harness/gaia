#!/usr/bin/env bash
# shellcheck shell=bash
#
# update-gaia-local-lib.sh: shared helpers for /update-gaia runs that merge a
# locally built bundle. Sourced by update-gaia-local.sh,
# update-gaia-preflight.sh and update-gaia-branch-state.sh; sourcing it has no
# side effects beyond defining the names below.
#
# A local build is identified by a build id `dev.<sha>` and, wherever a release
# tag is used, by the dev tag `v<core>-dev.<sha>`, where <core> is the bundle's
# plain x.y.z version. A dev tag ranks below its plain release and above every
# lower release by semver, while `sort -V` ranks it above its plain release, so
# tags are never ranked with `sort -V`: compare cores with
# gaia_local_version_below instead.
#
# Every helper is a plain function so the callers keep their literal-path
# command text (the worktree runtime refuses command substitution, variables in
# paths and heredocs in a command's text).

GAIA_LOCAL_BUILD_ID_PATTERN='^dev\.[0-9a-f]{7,40}$'
GAIA_LOCAL_TAG_PATTERN='^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)-dev\.[0-9a-f]{7,40}$'
GAIA_UPDATE_CACHE_ROOT='.gaia/local/cache/shared/update-gaia'
GAIA_LOCAL_LIB_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Returns 0 when $1 is one line, holds no slash and matches the build id shape.
# The newline test runs first because a multi-line value can satisfy an
# anchored pattern line by line in some regex engines.
gaia_local_is_build_id() {
  case "$1" in
    *$'\n'* | */*) return 1 ;;
  esac
  [[ "$1" =~ $GAIA_LOCAL_BUILD_ID_PATTERN ]]
}

# Returns 0 when $1 is a dev tag.
gaia_local_is_dev_tag() {
  case "$1" in
    *$'\n'*) return 1 ;;
  esac
  [[ "$1" =~ $GAIA_LOCAL_TAG_PATTERN ]]
}

# Prints the dev tag for core $1 and build id $2.
gaia_local_tag_for() {
  printf 'v%s-%s\n' "$1" "$2"
}

# Reads a build file. Absent: returns 1 and prints nothing. Present and valid:
# prints the trimmed id, returns 0. Present and invalid: returns 2, prints
# nothing, so a traversal-shaped or multi-line value never reaches a path.
gaia_local_read_build_file() {
  local content
  [ -e "$1" ] || return 1
  [ -f "$1" ] && [ -r "$1" ] || return 2
  content="$(cat "$1")" || return 2
  content="${content#"${content%%[![:space:]]*}"}"
  content="${content%"${content##*[![:space:]]}"}"
  gaia_local_is_build_id "$content" || return 2
  printf '%s\n' "$content"
}

# Returns 0 when x.y.z $1 is older than $2, through the shared vcmp.
gaia_local_version_below() {
  awk -v left="$1" -v right="$2" "$(cat "$GAIA_LOCAL_LIB_DIRECTORY/lib/version-compare.awk")"'
    BEGIN { exit !(vcmp(left, right) < 0) }
  '
}

# Prints the hex SHA-256 of file $1.
gaia_local_sha256() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{ print $1 }'
  else
    sha256sum "$1" | awk '{ print $1 }'
  fi
}

# Extracts tarball $1 into $2 (empty or absent) after listing it. One reason
# word on stdout and return 1 on a refusal: absolute-entry, parent-entry,
# link-entry, layout, list-failed, extract-failed. A listing check is the only
# guard before extraction, so every rule here runs on names the tool itself
# lists; GNU and BSD tar both print a link's target after ` -> ` or
# ` link to `, and a mode string beginning l or h.
gaia_local_safe_extract() {
  local tarball="$1" destination="$2" names verbose name first top=''
  names="$(tar -tzf "$tarball" 2>/dev/null)" || { echo list-failed; return 1; }
  verbose="$(tar -tvzf "$tarball" 2>/dev/null)" || { echo list-failed; return 1; }
  [ -n "$names" ] || { echo layout; return 1; }
  while IFS= read -r name; do
    case "$name" in
      /*) echo absolute-entry; return 1 ;;
    esac
    case "/$name/" in
      */../*) echo parent-entry; return 1 ;;
    esac
  done <<NAMES
$names
NAMES
  while IFS= read -r name; do
    case "$name" in
      l* | h* | *' -> '* | *' link to '*) echo link-entry; return 1 ;;
    esac
  done <<VERBOSE
$verbose
VERBOSE
  while IFS= read -r name; do
    case "$name" in
      */*) first="${name%%/*}" ;;
      *) echo layout; return 1 ;;
    esac
    case "$first" in
      '' | .) echo layout; return 1 ;;
    esac
    [ -n "$top" ] || top="$first"
    [ "$first" = "$top" ] || { echo layout; return 1; }
  done <<NAMES
$names
NAMES
  if [ -d "$destination" ] && [ -n "$(ls -A "$destination")" ]; then
    echo extract-failed
    return 1
  fi
  mkdir -p "$destination" || { echo extract-failed; return 1; }
  tar -xzf "$tarball" -C "$destination" --strip-components=1 >/dev/null 2>&1 || { echo extract-failed; return 1; }
}

# Re-verifies the cached local build for dev tag $1 and extracts tree/ fresh.
# Returns 3 when the tarball or its checksum is absent (nothing touched), 1 on
# a checksum that does not name exactly this tarball or does not match, 4 when
# the extraction is refused. The checksum is computed locally when the build is
# cached, so it guards only against cache corruption, never authenticity. The
# caller decides whether to remove the directory.
gaia_local_verify_cached() {
  local tag="$1" directory tarball expected
  gaia_local_is_dev_tag "$tag" || return 3
  directory="$GAIA_UPDATE_CACHE_ROOT/$tag"
  tarball="gaia-bundle-${tag}.tar.gz"
  [ -f "$directory/$tarball" ] && [ -f "$directory/$tarball.sha256" ] || return 3
  awk -v name="$tarball" 'NF == 2 && $2 == name { matched++ } END { exit !(NR == 1 && matched == 1) }' "$directory/$tarball.sha256" || return 1
  expected="$(awk '{ print $1 }' "$directory/$tarball.sha256")"
  [ "$(gaia_local_sha256 "$directory/$tarball")" = "$expected" ] || return 1
  rm -rf "$directory/tree"
  gaia_local_safe_extract "$directory/$tarball" "$directory/tree" >/dev/null || return 4
}
