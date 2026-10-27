#!/usr/bin/env bash
# Lints the shell files a pull request changed, minus every file GAIA owns.
#
# Usage: shellcheck-changed.sh --root <dir> [--manifest <file>]... [--select-only]
#
# Reads NUL-delimited changed paths (relative to --root) on stdin. Selects the
# paths ending `.sh` or `.bats` that exist as regular files under the root and
# that no given manifest lists as "owned". Pass the base and head manifests so
# a file GAIA owned on either side is never linted.
#
# --select-only prints the selection NUL-delimited and exits 0. Otherwise it
# runs `shellcheck -S warning --` over the selected `.sh` files and
# `shellcheck -S warning -s bash --` over the selected `.bats` files (bats is
# bash with `@test` sugar and carries no shebang shellcheck can read), once per
# type. The root's own `.shellcheckrc` applies: that is the adopter's policy.
#
# Exit: 0 when nothing is selected or every lint passes, shellcheck's status on
# a lint failure, 2 on a usage error, a missing or unparseable manifest, or a
# missing `jq`. A manifest the caller names but that does not exist is an
# error rather than an empty list, because the workflow only passes files it
# just wrote.

set -euo pipefail

root=""
select_only=0
manifests=()

while [ "$#" -gt 0 ]; do
  case "$1" in
    --root)
      [ "$#" -ge 2 ] || { echo "shellcheck-changed: --root needs a value" >&2; exit 2; }
      root="$2"
      shift 2
      ;;
    --manifest)
      [ "$#" -ge 2 ] || { echo "shellcheck-changed: --manifest needs a value" >&2; exit 2; }
      manifests+=("$2")
      shift 2
      ;;
    --select-only)
      select_only=1
      shift
      ;;
    *)
      echo "shellcheck-changed: unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

if [ -z "$root" ] || [ ! -d "$root" ]; then
  echo "shellcheck-changed: --root must name an existing directory" >&2
  exit 2
fi

newline=$'\n'
owned_framed="$newline"
if [ "${#manifests[@]}" -gt 0 ]; then
  command -v jq >/dev/null 2>&1 || { echo "shellcheck-changed: jq is required to read a manifest" >&2; exit 2; }
  for manifest in ${manifests[@]+"${manifests[@]}"}; do
    [ -f "$manifest" ] || { echo "shellcheck-changed: manifest not found: $manifest" >&2; exit 2; }
    manifest_owned="$(jq -r '.files | to_entries[] | select(.value == "owned") | .key' "$manifest")" \
      || { echo "shellcheck-changed: cannot parse manifest: $manifest" >&2; exit 2; }
    while IFS= read -r owned_path; do
      [ -n "$owned_path" ] && owned_framed="${owned_framed}${owned_path}${newline}"
    done <<< "$manifest_owned"
  done
fi

shell_files=()
bats_files=()
selected=()
while IFS= read -r -d '' path; do
  case "$path" in
    *.sh | *.bats) ;;
    *) continue ;;
  esac
  [ -f "$root/$path" ] || continue
  case "$owned_framed" in
    *"$newline$path$newline"*) continue ;;
  esac
  selected+=("$path")
  case "$path" in
    *.bats) bats_files+=("$root/$path") ;;
    *) shell_files+=("$root/$path") ;;
  esac
done

if [ "$select_only" -eq 1 ]; then
  [ "${#selected[@]}" -eq 0 ] || printf '%s\0' "${selected[@]}"
  exit 0
fi

[ "${#selected[@]}" -gt 0 ] || exit 0

command -v shellcheck >/dev/null 2>&1 || { echo "shellcheck-changed: shellcheck is not installed" >&2; exit 2; }

status=0
[ "${#shell_files[@]}" -eq 0 ] || shellcheck -S warning -- "${shell_files[@]}" || status=$?
if [ "${#bats_files[@]}" -gt 0 ]; then
  bats_status=0
  shellcheck -S warning -s bash -- ${bats_files[@]+"${bats_files[@]}"} || bats_status=$?
  [ "$status" -ne 0 ] || status="$bats_status"
fi
exit "$status"
