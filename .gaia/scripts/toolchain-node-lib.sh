#!/usr/bin/env bash
# shellcheck shell=bash
#
# The Node helpers toolchain-check.sh sources from its own folder, so a target
# bundle's copy runs with the same bundle's helpers. They read the caller's
# FLOORS_FILE, PLATFORM and PNPM_INSTALL globals.
#
# Bash 3.2 compatible. Never `cd`.

# node_floor_major: the major of the node row's floor in the floors file, read
# from FLOORS_FILE so /update-gaia's target bundle names the Node that clears
# its own floor. Prints nothing when the row is absent or the floor is not a
# number.
node_floor_major() {
  local tool floor _rest major=""
  while IFS=$'\t' read -r tool floor _rest; do
    [ "$tool" = node ] || continue
    major="${floor%%.*}"
    break
  done <"$FLOORS_FILE"
  case "$major" in '' | *[!0-9]*) major="" ;; esac
  printf '%s' "$major"
}

# node_version_manager: the version manager the node guide's commands run
# through, fnm or nvm, or nothing. nvm is a shell function, invisible to
# command -v here, so its install script stands in for it. Windows counts only
# fnm, the one manager its guide names.
node_version_manager() {
  if command -v fnm >/dev/null 2>&1; then
    printf 'fnm'
  elif [ "$PLATFORM" != windows ] && [ -s "${NVM_DIR:-${HOME:-}/.nvm}/nvm.sh" ]; then
    printf 'nvm'
  fi
}

# node_route: a terminal route through the version manager this machine has,
# or nothing. It is terminal because the new Node reaches only a new shell's
# PATH, and it sets the default so the profile each new shell sources keeps it.
# It installs the floor's Node major (node_floor_major), switches this terminal
# to it (use) so the pnpm reinstall runs under the new Node, and writes no project
# file, so it does not depend on its working directory. Windows gets no route:
# these commands are bash.
# shellcheck disable=SC2016
node_route() {
  local node_major
  [ "$PLATFORM" != windows ] || return 0
  node_major="$(node_floor_major)"
  [ -n "$node_major" ] || return 0
  case "$(node_version_manager)" in
    fnm) printf 'terminal fnm install %s && fnm use %s && fnm default %s && { %s; }' "$node_major" "$node_major" "$node_major" "$PNPM_INSTALL" ;;
    nvm) printf 'terminal nvm install %s && nvm use %s && nvm alias default %s && { %s; }' "$node_major" "$node_major" "$node_major" "$PNPM_INSTALL" ;;
  esac
}
