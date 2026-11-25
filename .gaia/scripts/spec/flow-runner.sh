#!/usr/bin/env bash
# Prints the gate line that runs a command flow's test, for the test stage to
# write into the closing flow-test phase: the run line of the runner
# flow-runners-lib.sh resolves for the path, placeholders in <angles>.
#
# Usage: flow-runner.sh <repo-relative test_path>
#
# Exit codes: 0 printed; 1 no flow runner runs the path (stderr says so);
# 2 usage error or an unreadable runner table. Bash 3.2 compatible.
set -uo pipefail

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=.gaia/scripts/spec/flow-runners-lib.sh
. "$script_directory/flow-runners-lib.sh"

if [ "$#" -ne 1 ] || [ -z "$1" ]; then
  printf 'usage: flow-runner.sh <repo-relative test_path>\n' >&2
  exit 2
fi

row=$(flow_runners_for_path "$script_directory/../../.." "$1")
case $? in
  0) ;;
  1) exit 1 ;;
  *) exit 2 ;;
esac
IFS=$'\t' read -r _ _ run _ <<<"$row"
printf '%s\n' "$run"
