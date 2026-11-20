#!/usr/bin/env bats

# Static guard for the context checkpoint doctrine: the file the checkpoint hook
# injects verbatim must stay under its byte budget and ship in a release. Run it with
# `.gaia/scripts/bats5.sh .gaia/tests/hooks/context-checkpoint-doctrine.bats < /dev/null`.

bats_require_minimum_version 1.5.0

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  DOCTRINE="$REPO_ROOT/.claude/doctrine/context-checkpoint.md"
  EXCLUDE="$REPO_ROOT/.gaia/release-exclude"
}

document_shape_ok() {
  local file_path="$1"
  [ -f "$file_path" ] || return 1
  [ "$(wc -c <"$file_path" | tr -d ' ')" -le 3584 ] || return 1
  [ "$(tail -c 1 "$file_path" | od -An -tx1 | tr -d ' \n')" = "0a" ] || return 1
  [ "$(tail -c 2 "$file_path" | od -An -tx1 | tr -d ' \n')" = "0a0a" ] && return 1
  LC_ALL=C grep -q $'[\x01-\x09\x0b-\x1f\x7f]' "$file_path" && return 1
  return 0
}

not_excluded_ok() {
  local exclude="$1" path="$2" line
  [ -f "$exclude" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in '' | '#'*) continue ;; esac
    line="${line%/}"
    [ -n "$line" ] || continue
    case "$path" in
      "$line" | "$line"/*) return 1 ;;
    esac
  done <"$exclude"
  return 0
}

@test "doctrine budget: byte cap, one trailing newline, no control characters" {
  document_shape_ok "$DOCTRINE"
}

@test "release-exclude: the doctrine file and the hook ship" {
  local shipped_path checked_count=0
  for shipped_path in .claude/doctrine/context-checkpoint.md .claude/hooks/context-checkpoint-inject.sh; do
    checked_count=$((checked_count + 1))
    not_excluded_ok "$EXCLUDE" "$shipped_path"
  done
  [ "$checked_count" -eq 2 ]
}
