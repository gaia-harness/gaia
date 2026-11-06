#!/usr/bin/env bash
# Holds a plan run's test authors to their file scope: the wave's New tests
# files and the stubs those tests import. A plan orchestrator takes one snapshot
# before a wave's first test author and checks the tree after each round of them,
# before the RED check, so an author that wrote implementation is caught while
# the test review can still run against stubs only.
#
# Usage:
#   author-scope.sh snapshot --root <tree root> --out <snapshot dir>
#   author-scope.sh check --root <tree root> --snapshot <snapshot dir> [--revert] --tests <file>...
#
# snapshot records every tracked path that differs from HEAD and every
# untracked, not-ignored path, with a copy of its content when it exists: a later wave starts
# on an earlier wave's uncommitted edits, so HEAD alone is the wrong baseline.
#
# check lists each path whose content changed since the snapshot (any tool:
# Edit, Write, a heredoc or a script) and is outside the allowed set:
#   - a --tests file (repo-relative; an absolute path under the root or a
#     trailing comma is accepted; an absolute path outside the root, an inner
#     comma or a `..` segment exits 2);
#   - a stub file: a file a --tests file imports through a relative or `~/`
#     specifier (`~/` is `<nearest package dir>/app/`). A stub file new since
#     the snapshot is allowed whole; one that existed may only gain lines, since
#     a stub adds a new export and an implementation rewrites existing code.
#     Implementation inside a new stub file, or added as new lines to an
#     existing one, is not caught here; the test review and the implementer's
#     stub replacement are the backstop.
# Import parsing is per line (`from '...'`, `import '...'`, `import('...')`);
# a specifier split across lines is missed, which errs toward a breach.
# Gitignored paths (such as .env) are out of this check's sight. The snapshot
# directory itself is never reported, whether or not it is ignored.
#
# Exit 0: in scope. Exit 1: one `<path><TAB><reason>` line per breach on
# stdout; with --revert each listed path is first restored to its snapshot
# content, or removed when it did not exist then. Exit 2: usage or setup error.
set -uo pipefail

die() { printf 'author-scope: %s\n' "$1" >&2; exit 2; }

mode="${1:-}"
[ "$#" -gt 0 ] && shift
root='' snapshot='' revert=0 tests=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --root) root="${2:-}"; shift 2 || shift ;;
    --out|--snapshot) snapshot="${2:-}"; shift 2 || shift ;;
    --revert) revert=1; shift ;;
    --tests) shift; while [ "$#" -gt 0 ] && [ "${1#--}" = "$1" ]; do tests+="$1"$'\n'; shift; done ;;
    *) die "unknown argument: $1" ;;
  esac
done
case "$mode" in snapshot|check) ;; *) die 'usage: author-scope.sh snapshot|check --root <tree root> ...' ;; esac
[ -n "$root" ] && [ -n "$snapshot" ] || die "$mode needs --root and a snapshot dir (--out or --snapshot)"
given_root="${root%/}"
root=$(git -C "$root" rev-parse --show-toplevel 2>/dev/null) || die "not a git work tree: $root"
if [ "$mode" = snapshot ]; then
  { rm -rf "$snapshot" && mkdir -p "$snapshot/files"; } || die "cannot create $snapshot"
fi
[ -d "$snapshot" ] || die "no snapshot at $snapshot"
# Physical path, so it compares with git's toplevel (macOS /var is /private/var).
snapshot=$(cd "$snapshot" && pwd -P)

# Snapshot dir relative to the root, when it lies inside it, so it is skipped.
snapshot_relative=''
case "$snapshot/" in "$root"/*) snapshot_relative="${snapshot#"$root"/}" ;; esac

# Paths that differ from HEAD (tracked) or are untracked and not ignored, one per line.
dirty_paths() {
  {
    git -C "$root" diff --name-only -z HEAD -- 2>/dev/null
    git -C "$root" ls-files -z --others --exclude-standard 2>/dev/null
  } | tr '\0' '\n' | while IFS= read -r path; do
    if [ -n "$snapshot_relative" ]; then
      case "$path/" in "$snapshot_relative"/*) continue ;; esac
    fi
    printf '%s\n' "$path"
  done | sort -u
}

if [ "$mode" = snapshot ]; then
  git -C "$root" rev-parse HEAD > "$snapshot/head" 2>/dev/null || die 'no HEAD commit'
  : > "$snapshot/present"
  : > "$snapshot/absent"
  dirty_paths | while IFS= read -r path; do
    if [ -f "$root/$path" ]; then
      mkdir -p "$snapshot/files/$(dirname "$path")"
      cp -p "$root/$path" "$snapshot/files/$path"
      printf '%s\n' "$path" >> "$snapshot/present"
    else
      printf '%s\n' "$path" >> "$snapshot/absent"
    fi
  done
  exit 0
fi

[ -f "$snapshot/head" ] || die "no snapshot at $snapshot"
[ -n "$tests" ] || die 'check needs --tests <file>...'
head=$(cat "$snapshot/head")

in_list() { grep -qxF -- "$1" "$2" 2>/dev/null; }

# Baseline of a path: "file", "head" or "none".
baseline_kind() {
  if in_list "$1" "$snapshot/present"; then printf 'file'
  elif in_list "$1" "$snapshot/absent"; then printf 'none'
  elif git -C "$root" cat-file -e "$head:$1" 2>/dev/null; then printf 'head'
  else printf 'none'
  fi
}

# Writes the baseline content of a path to stdout (empty for "none").
baseline_content() {
  case "$(baseline_kind "$1")" in
    file) cat "$snapshot/files/$1" ;;
    head) git -C "$root" cat-file blob "$head:$1" ;;
  esac
}

changed_since_snapshot() {
  local path="$1" kind
  kind=$(baseline_kind "$path")
  if [ ! -f "$root/$path" ]; then
    [ "$kind" != none ]
    return
  fi
  [ "$kind" = none ] && return 0
  [ "$(baseline_content "$path" | git hash-object --stdin)" != "$(git hash-object -- "$root/$path")" ]
}

# Collapses `.` and `..` segments of a relative path.
normalize() {
  local IFS=/ part out=''
  for part in $1; do
    case "$part" in
      ''|.) ;;
      ..) case "$out" in */*) out="${out%/*}" ;; *) out='' ;; esac ;;
      *) out="${out:+$out/}$part" ;;
    esac
  done
  printf '%s' "$out"
}

package_dir_of() {
  local directory
  directory=$(dirname "$1")
  while [ "$directory" != . ] && [ ! -f "$root/$directory/package.json" ]; do
    directory=$(dirname "$directory")
  done
  printf '%s' "$directory"
}

# Resolves one import specifier of a test file to an existing repo-relative path.
resolve_import() {
  local test_file="$1" specifier="$2" base candidate
  case "$specifier" in
    .*) base=$(normalize "$(dirname "$test_file")/$specifier") ;;
    \~/*) base=$(normalize "$(package_dir_of "$test_file")/app/${specifier#\~/}") ;;
    *) return 0 ;;
  esac
  for candidate in "$base" "$base.ts" "$base.tsx" "$base.js" "$base.jsx" "$base.mjs" \
    "${base%.js}.ts" "${base%.js}.tsx" "$base/index.ts" "$base/index.tsx" "$base/index.js"; do
    if [ -f "$root/$candidate" ]; then printf '%s\n' "$candidate"; return 0; fi
  done
}

work_directory=$(mktemp -d) || exit 2
trap 'rm -rf "$work_directory"' EXIT
allowed_tests="$work_directory/tests"
allowed_stubs="$work_directory/stubs"
# Halt on an unusable value before anything is reverted: reverting against an
# unmatched path would delete the author's own test file.
: > "$allowed_tests"
while IFS= read -r test_value; do
  [ -n "$test_value" ] || continue
  while [ "${test_value%,}" != "$test_value" ]; do test_value="${test_value%,}"; done
  case "$test_value" in
    "$root"/*) test_value="${test_value#"$root"/}" ;;
    "$given_root"/*) test_value="${test_value#"$given_root"/}" ;;
  esac
  case "$test_value" in
    /*|*,*|..|../*|*/..|*/../*) die "--tests value is not a repo-relative path inside the root: $test_value" ;;
  esac
  printf '%s\n' "$(normalize "$test_value")" >> "$allowed_tests"
done <<< "$tests"
sort -u "$allowed_tests" | sed '/^$/d' > "$allowed_tests.sorted" && mv "$allowed_tests.sorted" "$allowed_tests"
: > "$allowed_stubs"
while IFS= read -r test_file; do
  [ -f "$root/$test_file" ] || continue
  grep -oE "(from|import)[[:space:]]*\(?[[:space:]]*['\"][^'\"]+['\"]" "$root/$test_file" \
    | sed -E "s/.*['\"]([^'\"]+)['\"]$/\1/" \
    | while IFS= read -r specifier; do resolve_import "$test_file" "$specifier"; done
done < "$allowed_tests" | sort -u > "$allowed_stubs"

breaches="$work_directory/breaches"
: > "$breaches"
{ dirty_paths; cat "$snapshot/present" "$snapshot/absent"; } | sort -u | while IFS= read -r path; do
  changed_since_snapshot "$path" || continue
  in_list "$path" "$allowed_tests" && continue
  if in_list "$path" "$allowed_stubs"; then
    [ "$(baseline_kind "$path")" = none ] && continue
    if [ ! -f "$root/$path" ]; then
      printf '%s\tstub file deleted\n' "$path"
      continue
    fi
    deleted=$(baseline_content "$path" | diff - "$root/$path" | grep -c '^<')
    [ "$deleted" -eq 0 ] && continue
    printf '%s\tstub file edit removes or changes existing lines (a stub only adds)\n' "$path"
    continue
  fi
  printf '%s\toutside the tests and their stubs\n' "$path"
done > "$breaches"

[ -s "$breaches" ] || exit 0

if [ "$revert" -eq 1 ]; then
  cut -f1 "$breaches" | while IFS= read -r path; do
    case "$(baseline_kind "$path")" in
      file) mkdir -p "$root/$(dirname "$path")"; cp -p "$snapshot/files/$path" "$root/$path" ;;
      head) git -C "$root" restore --source="$head" --worktree -- "$path" ;;
      none) rm -f -- "$root/$path" ;;
    esac
  done
fi
cat "$breaches"
exit 1
