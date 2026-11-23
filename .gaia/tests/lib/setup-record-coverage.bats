#!/usr/bin/env bats
# Every setup feature the shipped list names is recorded somewhere on the
# setup surface, and the surface records no id the list does not hold.
#
# The surface is `.claude/commands/setup-gaia.md`, `.claude/commands/gaia-init.md`
# and every `.claude/skills/gaia/references/setup/*.md`. A record line counts
# only when it names the id literally (`gaia setup record <id> <value>`): a
# variable in the id position records nothing a reader can check.
#
# The id set is derived from `.gaia/setup-features.json`, and the reference
# set from the directory, so a feature or reference added later is covered
# without editing this suite.
#
# Assertion style: .claude/rules/bats-assertions.md.

# bats file_tags=whole-tree

setup() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)"
  FEATURE_LIST="${REPO_ROOT}/.gaia/setup-features.json"
  [ -f "$FEATURE_LIST" ] || {
    echo "the setup feature list is absent: ${FEATURE_LIST}" >&2
    return 1
  }
}

# listed_ids <list>: the ids of the feature list, one per line, in list order.
listed_ids() {
  jq -r '.features[].id' "$1"
}

# surface_files <root>: the surface files under <root>, one per line. Fails
# when a command is absent or the reference directory holds no file.
surface_files() {
  local root="$1" file count=0
  for file in "${root}/.claude/commands/setup-gaia.md" "${root}/.claude/commands/gaia-init.md"; do
    [ -f "$file" ] || {
      echo "a surface command is absent: ${file}" >&2
      return 1
    }
    printf '%s\n' "$file"
  done
  for file in "${root}/.claude/skills/gaia/references/setup"/*.md; do
    [ -f "$file" ] || continue
    count=$((count + 1))
    printf '%s\n' "$file"
  done
  [ "$count" -gt 0 ] || {
    echo "no setup reference under ${root}" >&2
    return 1
  }
}

# recorded_ids <root>: every kebab-case id a literal record line on the
# surface names, sorted and unique.
recorded_ids() {
  local files
  files="$(surface_files "$1")" || return 1
  while IFS= read -r file; do
    grep -oE 'gaia setup record [a-z0-9]+(-[a-z0-9]+)* ' "$file" || true
  done <<<"$files" | sed -E 's/^gaia setup record //; s/ $//' | sort -u
}

# check_every_id_recorded <root> <list>: each listed id has a literal record
# line; names every id that has none.
check_every_id_recorded() {
  local root="$1" list="$2" ids recorded id expected count=0 missing=""
  ids="$(listed_ids "$list")" || return 1
  expected="$(jq '.features | length' "$list")" || return 1
  recorded="$(recorded_ids "$root")" || return 1
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    count=$((count + 1))
    grep -qxF -- "$id" <<<"$recorded" || missing="${missing} ${id}"
  done <<<"$ids"
  if [ "$count" -eq 0 ] || [ "$count" -ne "$expected" ]; then
    echo "read ${count} ids from a list of ${expected}" >&2
    return 1
  fi
  [ -z "$missing" ] || {
    echo "listed ids with no literal record line:${missing}" >&2
    return 1
  }
}

# check_no_unknown_id <root> <list>: each id a record line names is listed;
# names every id that is not.
check_no_unknown_id() {
  local root="$1" list="$2" ids recorded id unknown=""
  ids="$(listed_ids "$list")" || return 1
  recorded="$(recorded_ids "$root")" || return 1
  [ -n "$recorded" ] || {
    echo "the surface carries no literal record line" >&2
    return 1
  }
  while IFS= read -r id; do
    grep -qxF -- "$id" <<<"$ids" || unknown="${unknown} ${id}"
  done <<<"$recorded"
  [ -z "$unknown" ] || {
    echo "record lines name ids the list does not hold:${unknown}" >&2
    return 1
  }
}

@test "the list holds ids, and the real surface records every one of them literally" {
  [ "$(listed_ids "$FEATURE_LIST" | grep -c .)" -gt 0 ]
  check_every_id_recorded "$REPO_ROOT" "$FEATURE_LIST"
}

@test "every literal record line on the real surface names a listed id" {
  check_no_unknown_id "$REPO_ROOT" "$FEATURE_LIST"
}
