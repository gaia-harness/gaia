#!/usr/bin/env bats
#
# Permanent guard that the retired /gaia-wiki stage arguments and the deleted
# `gaia wiki sync land` subcommand stay gone.
#
#   UAT-007: no tracked file outside the allowlist invokes a /gaia-wiki stage
#            (the stage name, a menu of stage names, a stage placeholder, or an
#            "any sub-command" note after the command), and every allowlist
#            entry still matches a hit. Both committed CLI bundles are tracked,
#            so a stale bundle string is caught too.
#   UAT-015: no tracked file outside the history ledgers and this guard's own
#            two files names the removed sync-land subcommand.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  ALLOWLIST="$REPO_ROOT/.gaia/tests/fixtures/wiki-stage-args-retired.allowlist"
  STAGE_PATTERN='/gaia-wiki`?[[:space:]]+`?(sync|consolidate|lint)([^[:alnum:]_]|$)|/gaia-wiki`?[[:space:]]*\[(sync|consolidate|lint)|/gaia-wiki`?[[:space:]]*<stage>|/gaia-wiki`?[[:space:]]*\(any sub-command\)'
  LAND_PATTERN='sync[ -]land'
}

# Allowlist lines with comments and blanks dropped.
allowlist_entries() {
  grep -vE '^[[:space:]]*(#|$)' "$1" || true
}

# True when path $1 matches any entry (a literal path or a glob) read from $2.
path_is_allowlisted() {
  local path="$1" entry
  while IFS= read -r entry; do
    # shellcheck disable=SC2254
    case "$path" in
      $entry) return 0 ;;
    esac
  done < <(allowlist_entries "$2")
  return 1
}

# Tracked files under root $1 matching the stage pattern. The log page is a scan
# exclusion: it changes each sync and can be hit-free, so the still-matches check
# must never apply to it.
stage_hit_files() {
  git -C "$1" grep -l -E "$STAGE_PATTERN" -- . ':!wiki/log.md' || true
}

# Print each stage hit under root $1 as path:line:text, for files matching no
# entry in allowlist $2.
unallowlisted_hits() {
  local root="$1" allowlist="$2" hit
  while IFS= read -r hit; do
    [ -n "$hit" ] || continue
    if ! path_is_allowlisted "$hit" "$allowlist"; then
      git -C "$root" grep -n -E "$STAGE_PATTERN" -- "$hit" | sed "s|^|$hit |" || true
    fi
  done < <(stage_hit_files "$root")
}

# Print each allowlist entry under root $1 that matches no hit.
unused_entries() {
  local root="$1" allowlist="$2" entry hit used hits
  hits="$(stage_hit_files "$root")"
  while IFS= read -r entry; do
    used=0
    while IFS= read -r hit; do
      [ -n "$hit" ] || continue
      # shellcheck disable=SC2254
      case "$hit" in
        $entry) used=1 ;;
      esac
    done <<<"$hits"
    [ "$used" -eq 1 ] || printf '%s\n' "$entry"
  done < <(allowlist_entries "$allowlist")
}

# The stage guard: exit 0 only when there is no offending hit and no unused entry.
guard_stage_args() {
  local root="$1" allowlist="$2" offenders unused
  offenders="$(unallowlisted_hits "$root" "$allowlist")"
  unused="$(unused_entries "$root" "$allowlist")"
  if [ -n "$offenders" ]; then
    printf 'not allowlisted:\n%s\n' "$offenders" >&2
  fi
  if [ -n "$unused" ]; then
    printf 'unused allowlist entries:\n%s\n' "$unused" >&2
  fi
  [ -z "$offenders" ] && [ -z "$unused" ]
}

# The sync-land scan: prints path:line for every hit outside the ledgers, the
# frozen routing fixture, and this guard's two files; exit 0 only when none.
guard_sync_land() {
  local root="$1" hits
  hits="$(git -C "$root" grep -n -E "$LAND_PATTERN" -- . \
    ':!CHANGELOG.md' ':!wiki/log.md' ':!wiki/meta/**' \
    ':!.gaia/tests/hooks/fixtures/audit-routing-before.tsv' \
    ':!.gaia/tests/lib/wiki-stage-args-retired.bats' \
    ':!.gaia/tests/fixtures/wiki-stage-args-retired.allowlist' || true)"
  if [ -n "$hits" ]; then
    printf 'sync land mentions:\n%s\n' "$hits" >&2
    return 1
  fi
  return 0
}

# bats test_tags=whole-tree
@test "UAT-007: no tracked file outside the allowlist invokes a retired stage, and no entry is unused" {
  run guard_stage_args "$REPO_ROOT" "$ALLOWLIST"
  echo "$output"
  [ "$status" -eq 0 ]
}

# bats test_tags=whole-tree
@test "UAT-015: no tracked file outside the ledgers names the removed sync-land subcommand" {
  run guard_sync_land "$REPO_ROOT"
  echo "$output"
  [ "$status" -eq 0 ]
}

@test "UAT-007: both committed CLI bundles are tracked" {
  local tracked
  tracked="$(git -C "$REPO_ROOT" ls-files -z -- .gaia/cli/gaia .gaia/cli/gaia-maintainer | tr '\0' '\n')"
  [[ "$tracked" == *".gaia/cli/gaia"$'\n'* ]]
  [[ "$tracked" == *".gaia/cli/gaia-maintainer" ]]
  [ "$(printf '%s\n' "$tracked" | wc -l | tr -d ' ')" -eq 2 ]
}
