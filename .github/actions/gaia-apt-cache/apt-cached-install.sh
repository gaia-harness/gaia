#!/usr/bin/env bash
# apt-cached-install.sh: run one apt install so that a slow or stalled Ubuntu
# mirror costs as little as possible, and a failure says how to recover.
#
# Usage:
#   apt-cached-install.sh --archive-dir <dir> --update-seconds <n>
#     --install-seconds <n> --attempts <n> -- <install command...>
#
# The install command runs as root with the caller's PATH, so it can be a
# plain `apt-get ... install ...` or a tool that runs apt itself, such as
# `playwright install-deps`. `--update-seconds 0` skips the separate
# `apt-get update`, for a command that runs its own.
#
# Two paths:
#
# Warm. When the archive directory already holds .deb files, they are the
# exact set an earlier cold run downloaded on the same runner image (the
# caller's cache key says so), and they install offline with
# `--no-download`: no `apt-get update`, no mirror. A warm install that fails
# for any reason falls through to the cold path rather than failing the step.
#
# Cold. Up to <attempts> tries of a bounded update and a bounded install, with
# apt pointed at the archive directory through an apt.conf.d snippet, so every
# .deb a try finishes downloading stays there and the next try does not fetch
# it again. On a slow but live mirror that turns three bounded tries into one
# download spread across them, rather than three restarts from zero. The same
# directory is what the caller caches for the next warm run.
#
# Bounds: Acquire::*::Timeout ends a stalled connection; the per-call
# `timeout` ends a call that is transferring, only slowly. Neither alone
# makes the retry reachable: the caller's step `timeout-minutes` must exceed
# attempts x (update + install) + the backoff below, which is
# 10 x attempts x (attempts - 1) / 2 seconds, plus one more install bound when
# the archive directory may be warm. That shorter formula holds only when the
# warm attempt fails fast.
#
# Exit status: 0 installed, 1 every attempt failed, 2 usage error.

set -uo pipefail

usage() {
  echo "usage: apt-cached-install.sh --archive-dir <dir> --update-seconds <n> --install-seconds <n> --attempts <n> -- <install command...>" >&2
  exit 2
}

archive_directory=""
update_seconds=""
install_seconds=""
attempts=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --archive-dir) [ "$#" -ge 2 ] || usage; archive_directory="$2"; shift 2 ;;
    --update-seconds) [ "$#" -ge 2 ] || usage; update_seconds="$2"; shift 2 ;;
    --install-seconds) [ "$#" -ge 2 ] || usage; install_seconds="$2"; shift 2 ;;
    --attempts) [ "$#" -ge 2 ] || usage; attempts="$2"; shift 2 ;;
    --) shift; break ;;
    *) usage ;;
  esac
done
[ -n "$archive_directory" ] && [ "$#" -gt 0 ] || usage
for number in "$update_seconds" "$install_seconds" "$attempts"; do
  case "$number" in '' | *[!0-9]*) usage ;; esac
done
[ "$install_seconds" -gt 0 ] && [ "$attempts" -gt 0 ] || usage

# Root already in a container; sudo on a hosted runner. `sudo timeout`, not
# `timeout sudo`: the latter signals sudo, which can leave the apt child
# running past the bound. `env PATH=` carries the caller's PATH past sudo's
# secure_path, so a tool from the job's Node toolchain still resolves.
as_root() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
  else
    sudo env PATH="$PATH" "$@"
  fi
}

# Exit 124 is timeout's own "I killed it", reported so a log reader can tell a
# bounded attempt from a failed one.
bounded() {
  local what="$1" seconds="$2" exit_status=0
  shift 2
  as_root timeout "$seconds" "$@" || exit_status=$?
  if [ "$exit_status" -eq 124 ]; then
    echo "apt ${what} exceeded its ${seconds}s bound" >&2
  fi
  return "$exit_status"
}

# Overridable only so a test can run this off a real runner without writing
# /etc.
apt_configuration="${APT_CONFIGURATION_FILE:-/etc/apt/apt.conf.d/90gaia-archive-cache}"

# apt runs as root and leaves a root-only partial/ and lock behind; the cache
# step that saves this directory runs as the runner user and cannot read them.
# shellcheck disable=SC2329 # invoked through the EXIT trap
release_archive_directory() {
  as_root rm -f "$apt_configuration"
  as_root rm -rf "$archive_directory/partial" "$archive_directory/lock"
  as_root chown -R "$(id -u):$(id -g)" "$archive_directory"
}
trap release_archive_directory EXIT

as_root mkdir -p "$archive_directory/partial"

# Written before the warm install as well as the cold one: offline, apt
# refuses a cached .deb that UPGRADES an installed package ("Pathname to
# install is not absolute") unless the directory holding it is apt's own
# archive cache.
printf '%s\n' \
  "Dir::Cache::Archives \"${archive_directory}/\";" \
  'APT::Keep-Downloaded-Packages "true";' \
  'Acquire::Retries "2";' \
  'Acquire::http::Timeout "20";' \
  'Acquire::https::Timeout "20";' |
  as_root tee "$apt_configuration" >/dev/null

cached_packages=("$archive_directory"/*.deb)
if [ -e "${cached_packages[0]}" ]; then
  if bounded "cached install" "$install_seconds" apt-get install -y --no-download --no-install-recommends "${cached_packages[@]}"; then
    echo "installed ${#cached_packages[@]} cached package(s) without contacting the mirror"
    exit 0
  fi
  echo "the cached packages did not install offline; falling back to the mirror" >&2
fi

for attempt in $(seq 1 "$attempts"); do
  if { [ "$update_seconds" -eq 0 ] || bounded update "$update_seconds" apt-get update; } \
    && bounded install "$install_seconds" "$@"; then
    exit 0
  fi
  echo "apt attempt ${attempt} of ${attempts} failed" >&2
  if [ "$attempt" -lt "$attempts" ]; then
    sleep $((attempt * 10))
  fi
done

echo "apt install failed after ${attempts} attempts, most likely a slow Ubuntu mirror. Recover by re-running the failed jobs: gh run rerun ${GITHUB_RUN_ID:-<run-id>} --failed" >&2
exit 1
