#!/usr/bin/env bash
# shellcheck shell=bash
#
# The bash reader of the package registry and descriptors. One of two
# implementations of one contract: the other is the CLI's TypeScript reader. A
# shared conformance corpus is the oracle both satisfy, error message text
# included, so a reason string changed here changes in the other. Node scripts
# outside the CLI bundle (the determinism classifier) read the registry through
# this library rather than carrying a reader of their own.
#
# CONTRACT WITH THE CALLER. Source this file, then call
# `gaia_packages_load <repo_root>` and branch on its status before any other
# function. A caller under `set -e` must capture the status
# (`gaia_packages_load "$root" || status=$?`) because 2, 3 and 4 are answers, not
# crashes. Status:
#   0  ok: the registry, or the built-in default registry when
#      `.gaia/packages.json` is absent, loaded and every descriptor validated
#   2  the registry is malformed, the built-in registry cannot be read, or no
#      repository root was given
#   3  a registered package's descriptor is missing, malformed or invalid
#   4  jq is not on PATH; nothing was read
# On any non-zero status `GAIA_PACKAGES_ERROR` holds one line beginning
# `gaia-packages:` and ending `Next step: <imperative>.`, and every query
# function answers as if nothing were loaded, so a guard that ignores the
# status sees an empty ERE rather than a stale one.
#
# FAIL-CLOSED. An absent registry is the built-in default (frontend at
# `frontend`), never "nothing in scope", and its descriptor is still read from
# `frontend/gaia.package.json`: a missing one is status 3, never a fallback. A
# present registry that fails any check returns an error and never a partial
# answer. A missing jq returns 4 rather
# than guessing: this library parses JSON with nothing else, so it cannot
# answer without it. Each caller's own missing-jq decision is in
# wiki/concepts/Claude Hooks.md ("Shared jq-availability decision").
#
# GLOB DIALECT: `**/` is zero or more whole directories, a trailing `/**`
# is everything beneath, `*` is any run excluding `/`, `?` is one character
# excluding `/`, `{a,b}` is non-nested alternation, every other character is
# literal. A glob compiles to an anchored ERE through control-character
# sentinels so a single `*` is never re-read as half of `**`; descriptor strings
# carrying control characters are refused before compiling, which keeps those
# sentinels private. All JSON values reach jq through `--arg` and stdin, never
# through shell interpolation, so a hostile registry path cannot run anything.
#
# Bash 3.2 compatible (no associative arrays, no mapfile); BSD and GNU tools.

if [ -n "${GAIA_PACKAGES_SH:-}" ]; then
  return 0
fi
GAIA_PACKAGES_SH=1

# shellcheck disable=SC2034 # GAIA_PACKAGES_ERROR is read by the sourcing caller
GAIA_PACKAGES_ERROR=''
_GAIA_PKG_SOURCE=''
_GAIA_PKG_GLOBS=''
_GAIA_PKG_LIST=''
_GAIA_PKG_ERE_tddUnitTests=''
_GAIA_PKG_ERE_tddStrictCandidates=''
_GAIA_PKG_ERE_emergentTests=''
_GAIA_PKG_ERE_preCommitSource=''
_GAIA_PKG_ERE_doctorConfigs=''
_GAIA_PKG_ERE_dependencyManifests=''

# The built-in default registry, used when `.gaia/packages.json` is absent. Its
# package's descriptor is read from disk like any registered package's, so the
# committed `gaia.package.json` is the one copy of the default globs.
_gaia_packages_builtin_registry() {
  cat <<'JSON'
[{"name":"frontend","path":"frontend"}]
JSON
}

# The jq program that reduces a parsed registry to the reason it is malformed,
# or the empty string when it is sound. Same checks, same order, same wording as
# the TypeScript reader's registry schema.
# shellcheck disable=SC2016 # a jq program: the dollar signs are jq variables, not shell expansions
_GAIA_PKG_REGISTRY_PROGRAM='
  def entry_reason($i):
    if type != "object" then "entry \($i) is not an object"
    elif ((.name | type) != "string") or ((.name | test("^[a-z][a-z0-9-]*$")) | not)
      then "entry \($i) name is invalid"
    elif ((.path | type) != "string")
      or ((.path | test("^(\\.|[a-z0-9][a-z0-9._-]*(/[a-z0-9][a-z0-9._-]*)*)$")) | not)
      then "entry \($i) path is invalid"
    else null end;
  def dup_reason:
    . as $all
    | [range(0; length) as $i
       | if ($all[:$i] | map(.name) | any(. == $all[$i].name)) then "entry \($i) name is a duplicate"
         elif ($all[:$i] | map(.path) | any(. == $all[$i].path)) then "entry \($i) path is a duplicate"
         else null end]
    | map(select(. != null)) | first // "";
  if type != "array" then "not a JSON array"
  else
    ([range(0; length) as $i | .[$i] | entry_reason($i)] | map(select(. != null)) | first)
      // dup_reason
  end
'

# The jq program that reduces a parsed descriptor to the reason it is invalid,
# or the empty string. `$n` is the registry name the descriptor must carry.
# Mirrors `descriptorIssueReason` in the TypeScript reader.
# shellcheck disable=SC2016 # a jq program: the dollar signs are jq variables, not shell expansions
_GAIA_PKG_DESCRIPTOR_PROGRAM='
  def clean: type == "string" and . != "" and ((test("[\\x00-\\x1f\\x7f]")) | not);
  def cleanlist: type == "array" and all(.[]; clean);
  . as $d
  | if ($d | type) != "object" then "not a JSON object"
    elif $d.schemaVersion != 1 then "schemaVersion must be 1"
    elif $d.name != $n then "name must be \"\($n)\""
    elif ($d.globs | type) != "object" then "globs must be an object"
    else
      ([("tddUnitTests","tddStrictCandidates","emergentTests","preCommitSource","doctorConfigs","dependencyManifests") as $k
        | select(($d.globs[$k] | cleanlist and length > 0) | not) | $k] | first) as $badglob
      | if $badglob != null then "globs.\($badglob) must be a non-empty array of non-empty strings without control characters"
        elif ($d.wiki | type) != "object" then "wiki must be an object"
        else
          ([("sourcePaths","inventoryPaths","flowPaths") as $k
            | select(($d.wiki[$k] | cleanlist) | not) | $k] | first) as $badwiki
          | if $badwiki != null then "wiki.\($badwiki) must be an array of strings without control characters"
            else "" end
        end
    end
'

# The jq program that compiles one descriptor to `key<TAB>body|body|...` lines,
# one per globs key, each glob joined to the package path `$p` first, then one
# `=key<TAB>joined-glob` line per glob for `gaia_package_globs`. A body has no
# anchors; the caller anchors the union. Same substitution sequence as
# `globToBody` in the TypeScript reader.
# shellcheck disable=SC2016 # a jq program: the dollar signs are jq variables, not shell expansions
_GAIA_PKG_COMPILE_PROGRAM='
  def body:
    gsub("(?<c>[\\\\.+^$()\\[\\]|])"; "\\" + .c)
    | gsub("\\*\\*/"; "\u0001")
    | gsub("\\*\\*"; "\u0002")
    | gsub("\\*"; "\u0003")
    | gsub("\\?"; "\u0004")
    | gsub("\\{(?<b>[^{}]+)\\}"; "\u0005" + (.b | gsub(","; "\u0007")) + "\u0006")
    | gsub("(?<c>[{}])"; "\\" + .c)
    | gsub("\u0001"; "(.*/)?")
    | gsub("\u0002"; ".*")
    | gsub("\u0003"; "[^/]*")
    | gsub("\u0004"; "[^/]")
    | gsub("\u0005"; "(")
    | gsub("\u0006"; ")")
    | gsub("\u0007"; "|");
  def joined($p): if $p == "." then . else $p + "/" + . end;
  . as $d
  | ("tddUnitTests","tddStrictCandidates","emergentTests","preCommitSource","doctorConfigs","dependencyManifests") as $k
  | ($d.globs[$k] | map(joined($p))) as $globs
  | ($k + "\t" + ($globs | map(body) | join("|"))), ($globs[] | "=" + $k + "\t" + .)
'

_gaia_packages_reset() {
  GAIA_PACKAGES_ERROR=''
  _GAIA_PKG_SOURCE=''
  _GAIA_PKG_GLOBS=''
  _GAIA_PKG_LIST=''
  _GAIA_PKG_ERE_tddUnitTests=''
  _GAIA_PKG_ERE_tddStrictCandidates=''
  _GAIA_PKG_ERE_emergentTests=''
    _GAIA_PKG_ERE_preCommitSource=''
  _GAIA_PKG_ERE_doctorConfigs=''
  _GAIA_PKG_ERE_dependencyManifests=''
}

# _gaia_packages_descriptor_file <package-path> -> the repo-relative descriptor path
_gaia_packages_descriptor_file() {
  if [ "$1" = . ]; then
    printf 'gaia.package.json\n'
  else
    printf '%s/gaia.package.json\n' "$1"
  fi
}

# _gaia_packages_registry_error <reason-or-empty>
_gaia_packages_registry_error() {
  local detail=''
  if [ -n "${1:-}" ]; then
    detail=": $1"
  fi
  GAIA_PACKAGES_ERROR="gaia-packages: .gaia/packages.json is malformed${detail}. Next step: fix .gaia/packages.json so it is a JSON array of {\"name\",\"path\"} entries, or delete it to use the built-in default."
}

# _gaia_packages_descriptor_error <file> <missing|malformed|invalid> [reason] [registry-source]
# A missing descriptor under the built-in registry has no registry path to
# correct, so its next step is the restore alone.
_gaia_packages_descriptor_error() {
  local file="$1" state="$2" reason="${3:-}" registry_source="${4:-}" status next
  if [ "$state" = missing ] && [ "$registry_source" = builtin ]; then
    next="restore it with git checkout origin/main -- ${file}, or run /update-gaia"
  elif [ "$state" = missing ]; then
    next="restore ${file} from the GAIA release, or correct the path in .gaia/packages.json"
  else
    next="restore ${file} from the GAIA release, or correct the field it names"
  fi
  status="$state"
  if [ "$state" = invalid ]; then
    status="invalid: ${reason}"
  fi
  GAIA_PACKAGES_ERROR="gaia-packages: ${file} is ${status}. Next step: ${next}."
}

# _gaia_packages_append_ere <key> <body-alternation>
_gaia_packages_append_ere() {
  local key="$1" body="$2" current
  case "$key" in
    tddUnitTests) current="$_GAIA_PKG_ERE_tddUnitTests" ;;
    tddStrictCandidates) current="$_GAIA_PKG_ERE_tddStrictCandidates" ;;
    emergentTests) current="$_GAIA_PKG_ERE_emergentTests" ;;
    preCommitSource) current="$_GAIA_PKG_ERE_preCommitSource" ;;
    doctorConfigs) current="$_GAIA_PKG_ERE_doctorConfigs" ;;
    dependencyManifests) current="$_GAIA_PKG_ERE_dependencyManifests" ;;
    *) return 1 ;;
  esac
  if [ -n "$current" ]; then
    current="${current}|${body}"
  else
    current="$body"
  fi
  case "$key" in
    tddUnitTests) _GAIA_PKG_ERE_tddUnitTests="$current" ;;
    tddStrictCandidates) _GAIA_PKG_ERE_tddStrictCandidates="$current" ;;
    emergentTests) _GAIA_PKG_ERE_emergentTests="$current" ;;
    preCommitSource) _GAIA_PKG_ERE_preCommitSource="$current" ;;
    doctorConfigs) _GAIA_PKG_ERE_doctorConfigs="$current" ;;
    dependencyManifests) _GAIA_PKG_ERE_dependencyManifests="$current" ;;
  esac
}

# _gaia_packages_compile_descriptor <package-path>   (descriptor JSON on stdin)
# Folds the descriptor's compiled globs into the per-key state. Returns 1 when
# jq fails, which cannot happen for a descriptor that already validated.
_gaia_packages_compile_descriptor() {
  local compiled line key body
  compiled=$(jq -r --arg p "$1" "$_GAIA_PKG_COMPILE_PROGRAM") || return 1
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in
      =*)
        _GAIA_PKG_GLOBS="${_GAIA_PKG_GLOBS}${line#=}"$'\n'
        continue
        ;;
    esac
    key="${line%%$'\t'*}"
    body="${line#*$'\t'}"
    _gaia_packages_append_ere "$key" "$body" || return 1
  done <<<"$compiled"
}

# gaia_packages_load <repo_root>
gaia_packages_load() {
  local root="${1:-}" registry_file registry_source entries name pkg_path descriptor_file
  local reason

  _gaia_packages_reset

  if ! command -v jq >/dev/null 2>&1; then
    GAIA_PACKAGES_ERROR='gaia-packages: jq is not on PATH, so the package registry cannot be read. Next step: install jq and retry.'
    return 4
  fi
  if [ -z "$root" ]; then
    GAIA_PACKAGES_ERROR='gaia-packages: no repository root was given. Next step: pass the repository root as the first argument.'
    return 2
  fi

  registry_file="$root/.gaia/packages.json"
  if [ ! -e "$registry_file" ] && [ ! -L "$registry_file" ]; then
    registry_source=builtin
    entries=$(_gaia_packages_builtin_registry | jq -r '.[] | .name + "\t" + .path') || {
      # shellcheck disable=SC2034 # read by the sourcing caller
      GAIA_PACKAGES_ERROR='gaia-packages: the built-in registry could not be read. Next step: report this as a GAIA bug.'
      return 2
    }
  else
    if ! jq -e -s 'length == 1' "$registry_file" >/dev/null 2>&1; then
      _gaia_packages_registry_error ''
      return 2
    fi
    if ! reason=$(jq -r "$_GAIA_PKG_REGISTRY_PROGRAM" "$registry_file" 2>/dev/null); then
      _gaia_packages_registry_error ''
      return 2
    fi
    if [ -n "$reason" ]; then
      _gaia_packages_registry_error "$reason"
      return 2
    fi
    registry_source=registry
    entries=$(jq -r '.[] | .name + "\t" + .path' "$registry_file") || {
      _gaia_packages_registry_error ''
      return 2
    }
  fi

  while IFS=$'\t' read -r name pkg_path; do
    [ -n "$name" ] || continue
    descriptor_file="$(_gaia_packages_descriptor_file "$pkg_path")"
    if [ ! -e "$root/$descriptor_file" ] && [ ! -L "$root/$descriptor_file" ]; then
      _gaia_packages_reset
      _gaia_packages_descriptor_error "$descriptor_file" missing '' "$registry_source"
      return 3
    fi
    if ! jq -e -s 'length == 1' "$root/$descriptor_file" >/dev/null 2>&1; then
      _gaia_packages_reset
      _gaia_packages_descriptor_error "$descriptor_file" malformed
      return 3
    fi
    if ! reason=$(jq -r --arg n "$name" "$_GAIA_PKG_DESCRIPTOR_PROGRAM" "$root/$descriptor_file" 2>/dev/null); then
      _gaia_packages_reset
      _gaia_packages_descriptor_error "$descriptor_file" malformed
      return 3
    fi
    if [ -n "$reason" ]; then
      _gaia_packages_reset
      _gaia_packages_descriptor_error "$descriptor_file" invalid "$reason"
      return 3
    fi
    _GAIA_PKG_LIST="${_GAIA_PKG_LIST}${name}"$'\t'"${pkg_path}"$'\n'
    if ! _gaia_packages_compile_descriptor "$pkg_path" <"$root/$descriptor_file"; then
      _gaia_packages_reset
      _gaia_packages_descriptor_error "$descriptor_file" malformed
      return 3
    fi
  done <<<"$entries"

  _GAIA_PKG_SOURCE="$registry_source"
  return 0
}

# gaia_packages_source ->`registry` or `builtin` (empty before a successful load)
gaia_packages_source() {
  printf '%s\n' "$_GAIA_PKG_SOURCE"
}

# gaia_packages_list -> `name<TAB>path` per line, registry order
gaia_packages_list() {
  if [ -n "$_GAIA_PKG_LIST" ]; then
    printf '%s' "$_GAIA_PKG_LIST"
  fi
}

# gaia_package_globs_ere <key> -> one anchored ERE over every package's joined
# globs for the key, or the empty string when no package declares it. Status 1
# on an unknown key.
gaia_package_globs_ere() {
  local body
  case "${1:-}" in
    tddUnitTests) body="$_GAIA_PKG_ERE_tddUnitTests" ;;
    tddStrictCandidates) body="$_GAIA_PKG_ERE_tddStrictCandidates" ;;
    emergentTests) body="$_GAIA_PKG_ERE_emergentTests" ;;
    preCommitSource) body="$_GAIA_PKG_ERE_preCommitSource" ;;
    doctorConfigs) body="$_GAIA_PKG_ERE_doctorConfigs" ;;
    dependencyManifests) body="$_GAIA_PKG_ERE_dependencyManifests" ;;
    *) return 1 ;;
  esac
  if [ -n "$body" ]; then
    printf '^(%s)$\n' "$body"
  else
    printf '\n'
  fi
}

# gaia_package_globs <key> -> every package's globs for the key, each joined to
# its package path, one per line in registry order. Empty before a successful
# load; status 1 on an unknown key.
gaia_package_globs() {
  local wanted="${1:-}" key glob
  gaia_package_globs_ere "$wanted" >/dev/null || return 1
  while IFS=$'\t' read -r key glob; do
    if [ "$key" = "$wanted" ]; then
      printf '%s\n' "$glob"
    fi
  done <<<"$_GAIA_PKG_GLOBS"
}

# gaia_package_for_path <repo-relative path> -> the owning package name, or
# empty. The package whose directory is the longest prefix owns the path; a
# package at `.` owns every path no deeper package claims.
gaia_package_for_path() {
  local target="${1:-}" best='' best_length=-1 name pkg_path length
  while IFS=$'\t' read -r name pkg_path; do
    [ -n "$name" ] || continue
    if [ "$pkg_path" = . ]; then
      length=0
    else
      case "$target" in
        "$pkg_path" | "$pkg_path"/*) length=${#pkg_path} ;;
        *) continue ;;
      esac
    fi
    if [ "$length" -gt "$best_length" ]; then
      best="$name"
      best_length="$length"
    fi
  done <<<"$_GAIA_PKG_LIST"
  printf '%s\n' "$best"
}

# gaia_package_dir <name> -> the registry path; status 1 when unknown
gaia_package_dir() {
  local wanted="${1:-}" name pkg_path
  while IFS=$'\t' read -r name pkg_path; do
    [ -n "$name" ] || continue
    if [ "$name" = "$wanted" ]; then
      printf '%s\n' "$pkg_path"
      return 0
    fi
  done <<<"$_GAIA_PKG_LIST"

  return 1
}
