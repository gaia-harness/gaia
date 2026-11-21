#!/usr/bin/env bash
#
# The scan-surface discovery the shell guards share: the tracked bats set, the
# named tracked sets, and their delta-mode narrowing. Sourced by guard-awk-lib.sh,
# whose header states the contract a consuming guard is written against; never
# run, and never sourced by a guard directly.

# Filled by gaia_guard_delta_intersect, read by its caller.
GAIA_GUARD_DELTA_KEPT=()

# gaia_guard_delta_intersect <guard-label> <surface> <path>...: fill
# GAIA_GUARD_DELTA_KEPT with the paths that GAIA_GUARD_DELTA_FILE also names,
# or with every path when that variable is empty. Return 0, or 3 having said so
# on stderr when the delta file cannot be read.
#
# GAIA_GUARD_DELTA_FILE names a NUL-delimited list of repo-relative paths: the
# delta mode `.gaia/tests/shell-lint.sh --paths-from` sets for the guards it
# names. A guard whose verdict on one file reads other files of its surface
# discovers that surface with the variable emptied and narrows only the files it
# reports on, or a hit the delta holds would be lost. Both discovery functions
# below intersect only after their own empty-set check, so a broken discovery is
# still a hard error in delta mode. An empty intersection is a clean skip, said on
# stderr: the delta holding none of a surface's file types is ordinary, and
# reporting it as a refusal would red every round whose delta holds no workflow.
gaia_guard_delta_intersect() {
  GAIA_GUARD_DELTA_KEPT=()
  local label="$1" surface="$2" delta_framed candidate_path
  shift 2
  if [ -z "${GAIA_GUARD_DELTA_FILE:-}" ]; then
    GAIA_GUARD_DELTA_KEPT=(${1+"$@"})
    return 0
  fi
  # A newline-framed copy and a case match rather than an associative array,
  # which bash 3.2 lacks; shell-lint.sh narrows its own passes the same way.
  if [ ! -r "$GAIA_GUARD_DELTA_FILE" ] || ! delta_framed="$(tr '\0' '\n' < "$GAIA_GUARD_DELTA_FILE")"; then
    printf '%s: ERROR: the delta file %s could not be read; nothing was scanned\n' \
      "$label" "$GAIA_GUARD_DELTA_FILE" >&2
    return 3
  fi
  delta_framed=$'\n'"$delta_framed"$'\n'
  for candidate_path in ${1+"$@"}; do
    case "$delta_framed" in
      *$'\n'"$candidate_path"$'\n'*) GAIA_GUARD_DELTA_KEPT+=("$candidate_path") ;;
    esac
  done
  if [ "${#GAIA_GUARD_DELTA_KEPT[@]}" -eq 0 ]; then
    printf '%s: delta mode: the delta holds no %s file; skipped\n' "$label" "$surface" >&2
  fi
  return 0
}

# Filled by gaia_guard_bats_files, read by its caller. Declared here so a caller
# that iterates before calling reads an empty array rather than an unset name.
GAIA_GUARD_BATS_FILES=()

# gaia_guard_bats_files <guard-label>: fill GAIA_GUARD_BATS_FILES with the
# tracked bats set (narrowed to the delta in delta mode) and return 0, or return
# 1 having said so on stderr when the discovery read nothing or the delta file
# could not be read.
#
# An empty bats surface is a hard error rather than a clean tree: the widened
# pathspec matching nothing means the discovery is wrong, and a guard that
# scanned no suite and printed clean is the lie-green failure these gates exist
# to stop. The status is the whole point of the shape, so the caller reads it
# directly (`gaia_guard_bats_files <label> || exit 1`) rather than through a
# substitution that would swallow it.
#
# `core.quotepath=false` and a NUL-delimited read, so a path carrying a
# non-ASCII byte is not handed over C-quoted and silently dropped. A read loop
# rather than mapfile, which is bash 4+, because these guards run on stock macOS
# /bin/bash 3.2.57.
gaia_guard_bats_files() {
  local label="${1:-guard}"
  local bats_file
  GAIA_GUARD_BATS_FILES=()
  while IFS= read -r -d '' bats_file; do
    GAIA_GUARD_BATS_FILES+=("$bats_file")
  done < <(git -c core.quotepath=false ls-files -z '*.bats' | LC_ALL=C sort -z)
  if [ "${#GAIA_GUARD_BATS_FILES[@]}" -eq 0 ]; then
    printf '%s: ERROR: no tracked bats suites matched the scan surface; nothing was scanned\n' "$label" >&2
    return 1
  fi
  if [ -n "${GAIA_GUARD_DELTA_FILE:-}" ]; then
    if ! gaia_guard_delta_intersect "$label" '*.bats' ${GAIA_GUARD_BATS_FILES[@]+"${GAIA_GUARD_BATS_FILES[@]}"}; then
      GAIA_GUARD_BATS_FILES=()
      return 1
    fi
    GAIA_GUARD_BATS_FILES=(${GAIA_GUARD_DELTA_KEPT[@]+"${GAIA_GUARD_DELTA_KEPT[@]}"})
  fi
  return 0
}

# Filled by gaia_guard_scan_files, read by its caller. Declared here so a caller
# that iterates before calling reads an empty array rather than an unset name.
GAIA_GUARD_SCAN_FILES=()

# _gaia_guard_scan_set <set-name>: emit that set's tracked paths NUL-delimited
# and return git's own status, or emit nothing and return 2 when the name is not
# one this library knows. Private to gaia_guard_scan_files, and the one place
# each pathspec is written.
#
#   shell      tracked `*.sh`, minus the hook directory the `githooks` set owns.
#              A git pathspec glob is matched without FNM_PATHNAME, so its `*`
#              crosses `/` and a `.githooks/helper.sh` would otherwise be returned
#              by both sets: scanned twice, and reported twice, by a caller that
#              asked for both.
#   githooks   the extensionless git hooks under `.githooks/`, which match no
#              extension glob, so a caller reads them as their own set rather
#              than folding them into `shell`.
#   workflows  the Actions workflows and composite actions.
#
# One set per call rather than one call carrying every pathspec: a `:(exclude)`
# magic pathspec applies to the whole call, so `shell`'s exclude would also
# empty a `githooks` set asked for in the same breath.
#
# `core.quotepath=false`, so a path carrying a non-ASCII byte is not handed over
# C-quoted and silently dropped.
_gaia_guard_scan_set() {
  case "$1" in
    shell) git -c core.quotepath=false ls-files -z '*.sh' ':(exclude).githooks/*' ;;
    githooks) git -c core.quotepath=false ls-files -z '.githooks/*' ;;
    workflows)
      git -c core.quotepath=false ls-files -z \
        '.github/workflows/*.yml' '.github/workflows/*.yaml' \
        '.github/actions/*/action.yml' '.github/actions/*/action.yaml'
      ;;
    *) return 2 ;;
  esac
}

# gaia_guard_scan_files <guard-label> <set>...: fill GAIA_GUARD_SCAN_FILES with
# the sorted union of the named tracked sets, having said on stderr what went
# wrong on any status but 0. The status is the whole point of the shape, so the
# caller reads it directly (`gaia_guard_scan_files <label> <set>... || exit 1`)
# rather than through a substitution that would swallow it.
#
# On any status but 0 the array is empty, never the surface a previous call left
# in it. That is a property of every refusing status below rather than of any one
# of them, which is why it is stated ahead of the list rather than beside an
# entry in it.
#
#   0  the union is non-empty and the array holds it, narrowed to the delta in
#      delta mode, where it may come back empty (gaia_guard_delta_intersect).
#   1  every named set resolved and the union came back empty. A hard error
#      rather than a clean tree, for the reason gaia_guard_bats_files states
#      about its own surface. This is the ONLY status a caller may tolerate,
#      and only where an empty surface is a legitimate tree for it.
#   2  the call itself is wrong: a set name this library does not know, no set
#      named at all, or one named twice. Either way the guard would scan a
#      surface other than the one it asked for and still report clean, which is
#      the discovery-stage failure `.claude/rules/guards-must-fail.md` names.
#   3  the discovery machinery failed: a named set's own `git ls-files`, the
#      sort, the scratch file each of them needs, or the delta file. Distinct from 1 because
#      the repairs differ, and distinct from a partial result because a set
#      that returned nothing on a failed call is otherwise indistinguishable
#      from one that legitimately matched nothing: with several sets asked for,
#      the survivors would carry the result past the empty check and the gate
#      would report clean over a surface it never opened.
#
# It really is a union: naming a set twice is refused rather than concatenated,
# so no path can reach the array twice and be scanned and reported twice. Across
# distinct names the sets are disjoint by construction, which is what lets the
# sort below leave out `-u`; a `-u` there would be a second mechanism
# guaranteeing the same thing, and a suite cannot red on either one alone while
# the other still holds.
#
# Nothing here is read through a process substitution, whose subshell cannot
# return its status to this function. That is what leaves a failure
# indistinguishable from an empty result, so every stage writes to a scratch
# file whose producer's status is read before the next stage runs. Every return
# path removes those files explicitly rather than through an EXIT trap: this
# library is sourced, so a trap installed here would replace whatever the
# consuming guard armed for its own cleanup.
#
# A read loop rather than mapfile, which is bash 4+, because these guards run on
# stock macOS /bin/bash 3.2.57.
gaia_guard_scan_files() {
  # Emptied before anything can return, so a caller that reads the array
  # after a refusal sees the nothing the refusal's message claims rather
  # than whatever the previous call left there.
  GAIA_GUARD_SCAN_FILES=()

  local label="${1:-guard}"
  if [ "$#" -lt 2 ]; then
    printf '%s: ERROR: gaia_guard_scan_files needs a label and at least one scan set\n' "$label" >&2
    return 2
  fi
  shift

  local scan_temporary_file sorted_temporary_file name status seen scan_file

  scan_temporary_file="$(mktemp -t gaia-guard-scan-XXXXXX)" || {
    printf '%s: ERROR: could not create a scratch file for the scan surface; nothing was scanned\n' "$label" >&2
    return 3
  }

  seen=""
  for name in "$@"; do
    case " $seen " in
      *" $name "*)
        rm -f "$scan_temporary_file"
        printf '%s: ERROR: scan set "%s" named more than once; nothing was scanned\n' "$label" "$name" >&2
        return 2
        ;;
    esac
    seen="$seen $name"

    # The `if` is what keeps a non-zero status readable: a bare call would abort
    # under the errexit every consuming guard arms before sourcing this library.
    if _gaia_guard_scan_set "$name" >> "$scan_temporary_file"; then
      status=0
    else
      status=$?
    fi
    if [ "$status" -eq 2 ]; then
      rm -f "$scan_temporary_file"
      printf '%s: ERROR: unknown scan set "%s"; nothing was scanned\n' "$label" "$name" >&2
      return 2
    fi
    if [ "$status" -ne 0 ]; then
      rm -f "$scan_temporary_file"
      printf '%s: ERROR: the %s discovery failed, git exited %s; nothing was scanned\n' \
        "$label" "$name" "$status" >&2
      return 3
    fi
  done

  sorted_temporary_file="$(mktemp -t gaia-guard-sort-XXXXXX)" || {
    rm -f "$scan_temporary_file"
    printf '%s: ERROR: could not create a scratch file to sort the scan surface; nothing was scanned\n' "$label" >&2
    return 3
  }
  if LC_ALL=C sort -z < "$scan_temporary_file" > "$sorted_temporary_file"; then
    status=0
  else
    status=$?
  fi
  rm -f "$scan_temporary_file"
  if [ "$status" -ne 0 ]; then
    rm -f "$sorted_temporary_file"
    printf '%s: ERROR: sorting the scan surface failed, sort exited %s; nothing was scanned\n' \
      "$label" "$status" >&2
    return 3
  fi

  while IFS= read -r -d '' scan_file; do
    GAIA_GUARD_SCAN_FILES+=("$scan_file")
  done < "$sorted_temporary_file"
  rm -f "$sorted_temporary_file"

  if [ "${#GAIA_GUARD_SCAN_FILES[@]}" -eq 0 ]; then
    printf '%s: ERROR: no tracked files matched the scan surface (%s); nothing was scanned\n' \
      "$label" "$*" >&2
    return 1
  fi
  if [ -n "${GAIA_GUARD_DELTA_FILE:-}" ]; then
    if ! gaia_guard_delta_intersect "$label" "$*" ${GAIA_GUARD_SCAN_FILES[@]+"${GAIA_GUARD_SCAN_FILES[@]}"}; then
      GAIA_GUARD_SCAN_FILES=()
      return 3
    fi
    GAIA_GUARD_SCAN_FILES=(${GAIA_GUARD_DELTA_KEPT[@]+"${GAIA_GUARD_DELTA_KEPT[@]}"})
  fi
  return 0
}
