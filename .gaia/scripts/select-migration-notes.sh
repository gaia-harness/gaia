#!/usr/bin/env bash
# shellcheck shell=bash
#
# Picks the migration notes an update crosses: every note in
# <bundle-root>/.gaia/migrations/ whose version is above <baseline> and at or
# below <target>, in ascending numeric order.
#
#   select-migration-notes.sh <bundle-root> <baseline x.y.z> <target x.y.z>
#
# Reads only <bundle-root>/.gaia/migrations/. A note is `<x.y.z>.md` opening
# with exactly three LF-terminated lines: `---`, `mode: blocking` or
# `mode: after-merge`, `---`. No byte-order mark, no carriage return anywhere.
# The folder holds nothing but notes.
#
# Output, one line per selected note:
#   <version><TAB><mode><TAB><bundle-root>/.gaia/migrations/<version>.md
# with the bundle root as given, one trailing `/` stripped.
#
# The whole folder is validated whatever the range, so one malformed or
# unreadable entry stops the update. Each such entry gets one stderr line,
# `select-migration-notes: <path>: <reason>`, stdout stays empty, exit 1.
#
# Exit codes: 0 selected notes (possibly none; an absent or empty folder is
# none), 1 a malformed or unreadable entry, 2 usage error.
#
# /update-gaia runs this script from the verified target bundle, never from
# the project's own tree, so a mode or key a later release adds is judged by
# that release's own selector. The version comparison is shared with
# changelog-range.sh in lib/version-compare.awk, loaded from this script's own
# install directory.

set -euo pipefail

usage() {
  echo "usage: select-migration-notes.sh <bundle-root> <baseline x.y.z> <target x.y.z>" >&2
  exit 2
}

[ "$#" -eq 3 ] || usage

component='(0|[1-9][0-9]*)'
version_pattern="^${component}\\.${component}\\.${component}\$"
note_pattern="^${component}\\.${component}\\.${component}\\.md\$"
[[ "$2" =~ $version_pattern ]] || usage
[[ "$3" =~ $version_pattern ]] || usage
[ -d "$1" ] || usage

baseline="$2"
target="$3"
bundle_root="${1%/}"
[ -n "$bundle_root" ] || bundle_root="/"
notes_dir="$bundle_root/.gaia/migrations"

compare_lib="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/version-compare.awk"
if [ ! -r "$compare_lib" ]; then
  echo "select-migration-notes: cannot read $compare_lib" >&2
  exit 2
fi
compare_src="$(cat "$compare_lib")"

failed=0
candidates=""
tab="$(printf '\t')"

fail() {
  echo "select-migration-notes: $1: $2" >&2
  failed=1
}

# check_note <path> <name>: validates one entry; on success appends
# "<version><TAB><mode>" to candidates.
check_note() {
  local path="$1" name="$2" version line1 line2 line3 mode

  # A symlink is tested first: -f and -d follow links.
  if [ -L "$path" ]; then
    fail "$path" "symlink, not a regular note"
    return 0
  fi
  if [ -d "$path" ]; then
    fail "$path" "directory, the folder holds only notes"
    return 0
  fi
  if [ ! -f "$path" ]; then
    fail "$path" "not a regular file"
    return 0
  fi
  if [[ ! "$name" =~ $note_pattern ]]; then
    fail "$path" "name is not a version note (<x.y.z>.md, no leading zeros)"
    return 0
  fi
  version="${name%.md}"
  if [ ! -r "$path" ]; then
    fail "$path" "unreadable"
    return 0
  fi
  if [ ! -s "$path" ]; then
    fail "$path" "empty file"
    return 0
  fi

  line1=""
  line2=""
  line3=""
  local bytes
  if ! bytes="$(LC_ALL=C tr -d -c '\r' <"$path" | LC_ALL=C wc -c)"; then
    fail "$path" "unreadable"
    return 0
  fi
  if [ "$((bytes + 0))" -ne 0 ]; then
    fail "$path" "carriage return found (LF line endings only)"
    return 0
  fi
  if [ "$(LC_ALL=C head -c 3 "$path" | LC_ALL=C od -An -tx1 | tr -d ' \n')" = "efbbbf" ]; then
    fail "$path" "byte-order mark found"
    return 0
  fi

  # read succeeds on a line only when an LF terminates it.
  if ! { IFS= read -r line1 && IFS= read -r line2 && IFS= read -r line3; } <"$path"; then
    fail "$path" "frontmatter incomplete: expected three LF-terminated lines (---, mode, ---)"
    return 0
  fi
  if [ "$line1" != "---" ] || [ "$line3" != "---" ]; then
    fail "$path" "frontmatter malformed: expected --- then one mode line then ---"
    return 0
  fi
  case "$line2" in
    "mode: blocking") mode="blocking" ;;
    "mode: after-merge") mode="after-merge" ;;
    *)
      fail "$path" "mode line must be exactly 'mode: blocking' or 'mode: after-merge'"
      return 0
      ;;
  esac
  candidates="${candidates}${version}${tab}${mode}
"
}

if [ -d "$notes_dir" ]; then
  shopt -s nullglob dotglob
  for entry in "$notes_dir"/*; do
    check_note "$entry" "${entry##*/}"
  done
  shopt -u nullglob dotglob
fi

[ "$failed" -eq 0 ] || exit 1
[ -n "$candidates" ] || exit 0

# Insertion sort ascending with vcmp, then keep baseline < version <= target.
printf '%s' "$candidates" | awk -F "$tab" -v OFS="$tab" \
  -v baseline="$baseline" -v target="$target" -v dir="$notes_dir" \
  "$compare_src"'
  { v[NR] = $1; m[NR] = $2 }
  END {
    for (i = 2; i <= NR; i++) {
      tv = v[i]; tm = m[i]; j = i - 1
      while (j >= 1 && vcmp(v[j], tv) > 0) { v[j+1] = v[j]; m[j+1] = m[j]; j-- }
      v[j+1] = tv; m[j+1] = tm
    }
    for (i = 1; i <= NR; i++)
      if (vcmp(v[i], baseline) > 0 && vcmp(v[i], target) <= 0)
        print v[i], m[i], dir "/" v[i] ".md"
  }
'
