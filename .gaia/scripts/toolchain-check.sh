#!/usr/bin/env bash
# shellcheck shell=bash
#
# toolchain-check.sh: compare this machine's tools with .gaia/toolchain-floors.tsv
# and print what to do about any that fall short.
#
#   bash .gaia/scripts/toolchain-check.sh [--scope user|all] [--tool <name>]
#                                         [--platform darwin|linux|windows]
#                                         [--os-id <id>] [--floors <file>]
#
# One line per tool checked, then a GUIDE line and, where an exact command
# exists, a ROUTE line per tool that fell short:
#   OK <tool> <installed> <floor>
#   BELOW <tool> <installed|unknown> <floor>
#   MISSING <tool> <floor>
#   GUIDE <tool>: <what to do>
#   ROUTE <tool> <run|user|terminal> <command>
# .claude/skills/gaia/references/toolchain.md (`## Below a floor`) says what
# each ROUTE class means to the caller.
#
# Exit 0 nothing fell short, 1 a tool fell short, 2 a usage error or an
# unreadable floors file. Callers stay silent on 0, so a machine at or above
# every floor sees no prompt.
#
# The default floors file is the one beside this script's own folder, so running
# a verified target bundle's copy of this script applies that release's floors.
# --scope user drops the tools GAIA installs itself, which is how /setup-gaia
# checks a fresh clone that has no pnpm yet.
#
# Everything here is a bash builtin or a tool being checked: this script is what
# tells a machine with no jq that it needs one. Guidance always routes to the
# latest release of a tool, never to its floor, and pins no version number.
#
# Bash 3.2 compatible. Never `cd`.

set -uo pipefail

PROGRAM_NAME="toolchain-check.sh"

usage() {
  printf 'Usage: bash .gaia/scripts/%s [--scope user|all] [--tool <name>]\n' "$PROGRAM_NAME"
  printf '         [--platform darwin|linux|windows] [--os-id <id>] [--floors <file>]\n'
}

script_directory="${BASH_SOURCE[0]%/*}"
[ "$script_directory" != "${BASH_SOURCE[0]}" ] || script_directory="."
FLOORS_FILE="$script_directory/../toolchain-floors.tsv"
SCOPE="all"
ONLY_TOOL=""
PLATFORM=""
OS_ID=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --scope | --tool | --platform | --os-id | --floors)
      [ "$#" -ge 2 ] || {
        printf '%s: %s needs a value\n' "$PROGRAM_NAME" "$1" >&2
        exit 2
      }
      case "$1" in
        --scope) SCOPE="$2" ;;
        --tool) ONLY_TOOL="$2" ;;
        --platform) PLATFORM="$2" ;;
        --os-id) OS_ID="$2" ;;
        --floors) FLOORS_FILE="$2" ;;
      esac
      shift 2
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      printf '%s: unrecognized argument: %s\n' "$PROGRAM_NAME" "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

case "$SCOPE" in
  user | all) ;;
  *)
    printf '%s: --scope must be user or all, got: %s\n' "$PROGRAM_NAME" "$SCOPE" >&2
    exit 2
    ;;
esac

if [ ! -r "$FLOORS_FILE" ]; then
  printf '%s: cannot read the floors file: %s\n' "$PROGRAM_NAME" "$FLOORS_FILE" >&2
  exit 2
fi

if [ -z "$PLATFORM" ]; then
  case "${OSTYPE:-}" in
    darwin*) PLATFORM=darwin ;;
    linux*) PLATFORM=linux ;;
    msys* | cygwin* | win*) PLATFORM=windows ;;
    *) PLATFORM=other ;;
  esac
fi

# The distribution family, from os-release: ID_LIKE names the family a derivative
# follows, and ID wins when it is itself a family this script routes.
read_os_id() {
  local key value id="" like=""
  [ -r /etc/os-release ] || return 0
  while IFS='=' read -r key value; do
    value="${value//\"/}"
    case "$key" in
      ID) id="$value" ;;
      ID_LIKE) like="$value" ;;
    esac
  done </etc/os-release
  printf '%s %s\n' "$id" "$like"
}
[ "$PLATFORM" != linux ] || [ -n "$OS_ID" ] || OS_ID="$(read_os_id)"

# Maps an os-release id list onto the family the routes below name.
os_family() {
  local word
  for word in $OS_ID; do
    case "$word" in
      ubuntu | debian | fedora | arch | alpine) printf '%s\n' "$word" && return 0 ;;
      rhel | centos | rocky | almalinux) printf 'rhel\n' && return 0 ;;
    esac
  done
  printf 'other\n'
}

# Homebrew on Linux tracks the current release of a package on any glibc
# distribution, which is what a distribution package cannot promise.
homebrew_route() {
  printf 'install Homebrew on Linux (https://brew.sh), run brew install %s, and put Homebrew'"'"'s bin folder first on PATH' "$1"
}

# package_route <package>: a route to the current release of a system package.
package_route() {
  local package="$1"
  case "$PLATFORM" in
    darwin)
      printf 'run brew install %s (Homebrew follows the current release), open a new shell, and confirm command -v %s prints Homebrew'"'"'s path' "$package" "$package"
      return 0
      ;;
    windows)
      case "$package" in
        jq) printf 'run winget install --id jqlang.jq -e' ;;
        *) printf 'run winget install --id Git.Git -e, which installs the current Git for Windows' ;;
      esac
      return 0
      ;;
  esac
  case "$(os_family)" in
    ubuntu)
      case "$package" in
        git) printf 'run sudo add-apt-repository ppa:git-core/ppa, then sudo apt-get update, then sudo apt-get install -y git; the plain Ubuntu archive stays behind' ;;
        *) printf 'apt stays behind, so %s' "$(homebrew_route "$package")" ;;
      esac
      ;;
    debian) printf 'apt stays behind on Debian stable, and backports can too, so %s' "$(homebrew_route "$package")" ;;
    rhel) printf 'dnf stays behind on enterprise releases, so %s' "$(homebrew_route "$package")" ;;
    fedora) printf 'run sudo dnf upgrade --refresh %s' "$package" ;;
    arch) printf 'run sudo pacman -Syu %s' "$package" ;;
    alpine) printf 'run sudo apk add --upgrade %s --repository=https://dl-cdn.alpinelinux.org/alpine/edge/main' "$package" ;;
    *) printf '%s' "$(homebrew_route "$package")" ;;
  esac
}

# socket_tool_route <tool>: a route to the tool holding listener lookup. Any
# release does the job, so the distribution's own package is fine here.
socket_tool_route() {
  case "$1" in
    lsof)
      printf 'it ships with macOS at /usr/sbin/lsof, so add /usr/sbin to PATH (Homebrew has no lsof that reaches PATH)'
      return 0
      ;;
  esac
  case "$(os_family)" in
    ubuntu | debian) printf 'run sudo apt-get install -y iproute2' ;;
    fedora | rhel) printf 'run sudo dnf install -y iproute' ;;
    arch) printf 'run sudo pacman -S iproute2' ;;
    alpine) printf 'run sudo apk add iproute2' ;;
    *) printf 'install your distribution'"'"'s iproute2 package' ;;
  esac
}

# Why GAIA needs the tool: the stop message's explanation.
tool_reason() {
  case "$1" in
    git) printf 'GAIA'"'"'s light audit review replays the merge with git merge-tree --merge-base.' ;;
    jq) printf 'GAIA'"'"'s hooks and scripts read JSON with it.' ;;
    pnpm) printf 'GAIA installs, tests and builds with it.' ;;
    lsof | ss) printf 'dev-smoke finds the running dev server with it.' ;;
  esac
}

guide() {
  local tool="$1" lead
  case "$tool" in
    git | jq)
      lead="Update to the latest $tool"
      printf 'GUIDE %s: %s: %s. %s\n' "$tool" "$lead" "$(package_route "$tool")" "$(tool_reason "$tool")"
      ;;
    pnpm)
      printf 'GUIDE pnpm: Update to the latest pnpm: run corepack disable pnpm if you use corepack, then npm install -g pnpm@latest. If an older pnpm still wins on PATH, upgrade or remove that install. %s\n' "$(tool_reason pnpm)"
      ;;
    *)
      printf 'GUIDE %s: Install %s: %s. %s\n' "$tool" "$tool" "$(socket_tool_route "$tool")" "$(tool_reason "$tool")"
      ;;
  esac
}

# The official Homebrew installer. It is interactive and asks for a password,
# so it is only ever handed to the user for their own terminal. The text stays
# unexpanded: it is printed for the user's shell, never run here.
# shellcheck disable=SC2016
HOMEBREW_INSTALLER='/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'

# brew_route <package>: brew installs it when Homebrew is here; otherwise the
# user installs Homebrew first, in a fresh terminal.
brew_route() {
  if command -v brew >/dev/null 2>&1; then
    printf 'run brew install %s' "$1"
  else
    printf 'terminal %s' "$HOMEBREW_INSTALLER"
  fi
}

# route_for <tool>: "<class> <command>" for the ROUTE line, or nothing when no
# exact command exists. The class tells the caller who runs it: run (Claude,
# after asking), user (the user, as `! <command>`: it needs sudo) or terminal
# (the user, in a fresh terminal: it is interactive or changes PATH).
route_for() {
  local tool="$1"
  case "$tool" in
    pnpm)
      printf 'run corepack disable pnpm 2>/dev/null; npm install -g pnpm@latest'
      return 0
      ;;
    lsof)
      # macOS ships lsof at /usr/sbin/lsof and Homebrew's is keg-only, so no
      # command can clear a missing one: print no ROUTE and let the GUIDE speak.
      return 0
      ;;
    ss)
      case "$(os_family)" in
        ubuntu | debian) printf 'user sudo apt-get install -y iproute2' ;;
        fedora | rhel) printf 'user sudo dnf install -y iproute' ;;
        arch) printf 'user sudo pacman -S --noconfirm iproute2' ;;
        alpine) printf 'user sudo apk add iproute2' ;;
      esac
      return 0
      ;;
  esac
  case "$PLATFORM" in
    darwin)
      brew_route "$tool"
      return 0
      ;;
    windows)
      case "$tool" in
        jq) printf 'terminal winget install --id jqlang.jq -e' ;;
        *) printf 'terminal winget install --id Git.Git -e' ;;
      esac
      return 0
      ;;
  esac
  case "$(os_family):$tool" in
    ubuntu:git) printf 'user sudo add-apt-repository -y ppa:git-core/ppa && sudo apt-get update && sudo apt-get install -y git' ;;
    fedora:*) printf 'user sudo dnf upgrade --refresh -y %s' "$tool" ;;
    arch:*) printf 'user sudo pacman -Syu --noconfirm %s' "$tool" ;;
    alpine:*) printf 'user sudo apk add --upgrade %s --repository=https://dl-cdn.alpinelinux.org/alpine/edge/main' "$tool" ;;
    *) brew_route "$tool" ;;
  esac
}

# The first dotted number in a --version line, or nothing.
installed_version() {
  local line
  line="$("$1" --version 2>/dev/null)" || return 0
  line="${line%%$'\n'*}"
  [[ "$line" =~ ([0-9]+(\.[0-9]+)+|[0-9]+) ]] && printf '%s\n' "${BASH_REMATCH[1]}"
}

# 0 when dotted version $1 is at or above dotted version $2, compared by number.
version_at_least() {
  local left="$1." right="$2." left_part right_part
  while [ -n "$left" ] || [ -n "$right" ]; do
    left_part="${left%%.*}"
    right_part="${right%%.*}"
    left="${left#*.}"
    right="${right#*.}"
    [ "$((10#${left_part:-0}))" -gt "$((10#${right_part:-0}))" ] && return 0
    [ "$((10#${left_part:-0}))" -lt "$((10#${right_part:-0}))" ] && return 1
  done
  return 0
}

short_tools=""

tab="$(printf '\t')"
while IFS="$tab" read -r tool floor platform upgrade; do
  case "$tool" in '' | '#'*) continue ;; esac
  [ -z "$ONLY_TOOL" ] || [ "$tool" = "$ONLY_TOOL" ] || continue
  [ "$platform" = any ] || [ "$platform" = "$PLATFORM" ] || continue
  [ "$SCOPE" = all ] || [ "$upgrade" = user ] || continue

  if ! command -v "$tool" >/dev/null 2>&1; then
    printf 'MISSING %s %s\n' "$tool" "$floor"
    short_tools="$short_tools $tool"
    continue
  fi
  if [ "$floor" = "-" ]; then
    printf 'OK %s present -\n' "$tool"
    continue
  fi
  version="$(installed_version "$tool")"
  if [ -z "$version" ]; then
    printf 'BELOW %s unknown %s\n' "$tool" "$floor"
    short_tools="$short_tools $tool"
  elif version_at_least "$version" "$floor"; then
    printf 'OK %s %s %s\n' "$tool" "$version" "$floor"
  else
    printf 'BELOW %s %s %s\n' "$tool" "$version" "$floor"
    short_tools="$short_tools $tool"
  fi
done <"$FLOORS_FILE"

for tool in $short_tools; do
  guide "$tool"
  route="$(route_for "$tool")"
  [ -z "$route" ] || printf 'ROUTE %s %s\n' "$tool" "$route"
done

[ -z "$short_tools" ] || exit 1
exit 0
