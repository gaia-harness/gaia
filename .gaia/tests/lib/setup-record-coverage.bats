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
  SETUP_COMMAND="${REPO_ROOT}/.claude/commands/setup-gaia.md"
  INIT_COMMAND="${REPO_ROOT}/.claude/commands/gaia-init.md"
  REFERENCES_DIRECTORY="${REPO_ROOT}/.claude/skills/gaia/references/setup"
  [ -f "$FEATURE_LIST" ] || {
    echo "the setup feature list is absent: ${FEATURE_LIST}" >&2
    return 1
  }
}

# listed_ids <list>: the ids of the feature list, one per line, in list order.
listed_ids() {
  jq -r '.features[].id' "$1"
}

# surface_copy <name>: copy the surface into a scratch directory laid out as
# the repository is, and print the directory.
surface_copy() {
  local directory="${BATS_TEST_TMPDIR}/$1"
  mkdir -p "${directory}/.claude/commands" "${directory}/.claude/skills/gaia/references/setup"
  cp "$SETUP_COMMAND" "$INIT_COMMAND" "${directory}/.claude/commands/"
  cp "${REFERENCES_DIRECTORY}"/*.md "${directory}/.claude/skills/gaia/references/setup/"
  printf '%s\n' "$directory"
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

@test "the coverage check names an id whose record lines are removed from a surface copy" {
  local root file
  root="$(surface_copy missing-id)"
  while IFS= read -r file; do
    sed -i.bak '/gaia setup record squash-only /d' "$file"
    rm -f "${file}.bak"
  done < <(surface_files "$root")
  run check_every_id_recorded "$root" "$FEATURE_LIST"
  [ "$status" -ne 0 ]
  grep -qF 'squash-only' <<<"$output"
}

@test "the coverage check fails on a list longer than the ids it reads" {
  local list="${BATS_TEST_TMPDIR}/longer.json"
  jq '.features += [{"id": "added-later", "scope": "machine", "required": false, "admin": false, "standalone": true, "reference": "x"}]' \
    "$FEATURE_LIST" >"$list"
  run check_every_id_recorded "$REPO_ROOT" "$list"
  [ "$status" -ne 0 ]
  grep -qF 'added-later' <<<"$output"
}

@test "the unknown-id check names an id the list does not hold" {
  local root
  root="$(surface_copy unknown-id)"
  printf '\n.gaia/cli/gaia setup record not-a-feature applied\n' \
    >>"${root}/.claude/skills/gaia/references/setup/squash-only.md"
  run check_no_unknown_id "$root" "$FEATURE_LIST"
  [ "$status" -ne 0 ]
  grep -qF 'not-a-feature' <<<"$output"
}
