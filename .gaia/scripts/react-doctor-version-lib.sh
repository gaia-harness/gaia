#!/usr/bin/env bash
# Owns the accepted format of .gaia/react-doctor-version. install-react-doctor.sh and
# audit-frontend-oracles.sh source it; the CLI's `update-deps global-tools` pin reader
# reimplements it, and a parity test beside that reader fails when the two disagree.

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
