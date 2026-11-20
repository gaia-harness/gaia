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
# gaia-spec, gaia-plan and gaia-test close a `spec:` or `plan:` ref from their
# own save, archive and stage-record steps, which their own suites pin, so they
# are left out here.
#
# Assertion style: .claude/rules/bats-assertions.md.

setup_file() {
  REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../../.." && pwd)"
  START_SET="$(bash -c '. "$1"; printf "%s" "$GAIA_USAGE_START_SET"' _ "${REPO_ROOT}/.gaia/scripts/usage-lib.sh")"
  export REPO_ROOT START_SET
}

# Prints the command workflows of the start set, one per line.
command_workflows() {
  jq -r '.[] | select(. != "gaia-spec" and . != "gaia-plan" and . != "gaia-test")' <<<"$START_SET"
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
