#!/usr/bin/env bats
#
# Doc-pin: every maintenance command in the usage start set closes its run.
# The flusher writes a start binding for each workflow in GAIA_USAGE_START_SET,
# and only `usage.sh record` closes it, so a command whose playbook stops
# recording leaves an open start and shows the user no Cost line. A command
# records either through the shared recipe (`{{COMMAND}}` = `<workflow>` inside
# a `## Cost record (run end)` section) or with a literal
# `usage.sh record command:<workflow>` call.
#
# gaia-spec and gaia-plan close a `spec:` or `plan:` ref from their own save
# and archive steps, which their own suites pin, so they are left out here.
#
# The check is a function over a file list, so the test that proves the real
# tree passes has twins that run it over scratch copies and assert it fails.
#
# Assertion style: .claude/rules/bats-assertions.md.

setup_file() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)"
  START_SET="$(bash -c '. "$1"; printf "%s" "$GAIA_USAGE_START_SET"' _ "${REPO_ROOT}/.gaia/scripts/usage-lib.sh")"
  export REPO_ROOT START_SET
}

# Prints the command workflows of the start set, one per line.
command_workflows() {
  jq -r '.[] | select(. != "gaia-spec" and . != "gaia-plan")' <<<"$START_SET"
}

# Prints the run-end section of every file named: from its heading to the
# next level-2 heading.
cost_record_sections() {
  awk '
    FNR == 1 { inside = 0 }
    /^## Cost record \(run end\)/ { inside = 1; next }
    inside && /^## / { inside = 0 }
    inside { print }
  ' "$@"
}

# Succeeds when one of the files named on stdin records the workflow's run.
workflow_records_its_run() {
  local workflow="$1" file
  local -a files=()
  while IFS= read -r file; do
    [ -f "$file" ] && files+=("$file")
  done
  [ "${#files[@]}" -gt 0 ] || return 1
  grep -qF -- "usage.sh record command:${workflow} " "${files[@]}" && return 0
  cost_record_sections "${files[@]}" | grep -qF -- "\`{{COMMAND}}\` = \`${workflow}\`"
}

@test "the start set names command workflows to check" {
  [ -n "$(command_workflows)" ]
}

# bats test_tags=whole-tree
@test "every command workflow in the start set records its run" {
  local workflow playbooks missing=""
  playbooks="$(git -C "$REPO_ROOT" ls-files -z -- '.claude/*.md' | tr '\0' '\n' | sed "s|^|${REPO_ROOT}/|")"
  [ -n "$playbooks" ]
  while IFS= read -r workflow; do
    workflow_records_its_run "$workflow" <<<"$playbooks" || missing="${missing} ${workflow}"
  done < <(command_workflows)
  [ -z "$missing" ] || {
    echo "no playbook records the run of:${missing}" >&2
    return 1
  }
}

@test "red twin: a playbook with its run-end section removed fails the check" {
  local scratch="${BATS_TEST_TMPDIR}/wiki.md"
  awk '
    /^## Cost record \(run end\)/ { skip = 1; next }
    skip && /^## / { skip = 0 }
    !skip { print }
  ' "${REPO_ROOT}/.claude/skills/gaia/references/wiki.md" >"$scratch"
  grep -qF '## Sync' "$scratch"
  run workflow_records_its_run gaia-wiki <<<"$scratch"
  [ "$status" -ne 0 ]
}

@test "red twin: a run-end section naming another command fails the check" {
  local scratch="${BATS_TEST_TMPDIR}/other.md"
  printf '## Cost record (run end)\n\nApply the recipe with `{{COMMAND}}` = `update-gaia`.\n' >"$scratch"
  run workflow_records_its_run update-deps <<<"$scratch"
  [ "$status" -ne 0 ]
}

@test "red twin: the recipe line outside a run-end section fails the check" {
  local scratch="${BATS_TEST_TMPDIR}/outside.md"
  printf '## Notes\n\nApply the recipe with `{{COMMAND}}` = `update-deps`.\n' >"$scratch"
  run workflow_records_its_run update-deps <<<"$scratch"
  [ "$status" -ne 0 ]
}

@test "red twin: a section that ends before the recipe line in a second file fails the check" {
  local first="${BATS_TEST_TMPDIR}/first.md" second="${BATS_TEST_TMPDIR}/second.md"
  printf '## Cost record (run end)\n\nNothing here.\n' >"$first"
  printf 'Apply the recipe with `{{COMMAND}}` = `update-deps`.\n' >"$second"
  run workflow_records_its_run update-deps < <(printf '%s\n' "$first" "$second")
  [ "$status" -ne 0 ]
}

@test "the real wiki playbook passes the check it fails without its section" {
  workflow_records_its_run gaia-wiki <<<"${REPO_ROOT}/.claude/skills/gaia/references/wiki.md"
}
