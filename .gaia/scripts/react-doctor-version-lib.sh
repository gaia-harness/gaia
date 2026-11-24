#!/usr/bin/env bash
# Owns the accepted format of .gaia/react-doctor-version. install-react-doctor.sh and
# audit-frontend-oracles.sh source it; the CLI's `update-deps global-tools` pin reader
# reimplements it, and a parity test beside that reader fails when the two disagree.

# The dependency manifests at the project root. Other scripts that list them name this array in a
# marker, and the test-scope selector builds its install inputs from it.
# shellcheck disable=SC2034 # read by the scripts that source this library
dependency_manifest_files=(package.json pnpm-lock.yaml pnpm-workspace.yaml)

# react_doctor_pinned_version <version file>: prints the pinned react-doctor version, or names the
# file on stderr and returns 1 when it is missing or holds anything but MAJOR.MINOR.PATCH, so no
# caller ever falls back to an unpinned run.
react_doctor_pinned_version() {
  local pinned_version=""
  if [ -f "$1" ]; then
    pinned_version="$(tr -d '[:space:]' <"$1")"
  fi
  if ! grep -Eqx '[0-9]+\.[0-9]+\.[0-9]+' <<<"$pinned_version"; then
    printf '%s holds no version such as 0.9.22\n' "$1" >&2
    return 1
  fi
  printf '%s\n' "$pinned_version"
}
