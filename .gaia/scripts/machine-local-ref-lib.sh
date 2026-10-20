#!/usr/bin/env bash
# shellcheck shell=bash
#
# The one detector for machine-local references: a SPEC, UAT or plan number,
# or a concrete path under .notebook/ or .gaia/local/ that one machine
# generated. The commit-msg hook, the pre-commit hook and the UAT gate's
# Playwright scan call it; the rule it enforces is
# .claude/rules/working-doc-ids.md. Dual-mode: source it for the functions
# below, or run it directly.
#
#   machine-local-ref-lib.sh text <file|->     scan every line
#   machine-local-ref-lib.sh message <file>    scan a commit message
#   machine-local-ref-lib.sh staged <root>     scan the lines a commit adds
#   machine-local-ref-lib.sh tracked <root>    scan every tracked file
#   machine-local-ref-lib.sh check message|staged <file|root>
#                                              the hooks' call: scan and explain
#   machine-local-ref-lib.sh explain           print what to do about a hit
#
# Exit codes: 0 clean, 1 one hit per stdout line (`line <n>: <match>` for text
# and message, `<path>:<line>: <match>` for staged and tracked), 2 usage error
# or unreadable input. check folds 2 into 1, so a hook refuses on any
# non-zero.
#
# Honest limits: a pattern match, so prose that only looks like an id is
# refused too, and the fix is to write the placeholder form. In code it reads
# full-line comments only, never a trailing comment or a string, so an id in a
# string literal passes: in code an id is far more often data than citation.
# In the staged and tracked scans, test files and fixtures are data and are never read.

# The match logic, shared by every verb. Inputs set with -v:
#   mode     text | message | file | diff
#   style    prose | hash | slash | both (which lines of a file are read)
#   strict   1 refuses an id in any case at any length
# An id is SPEC, UAT or PLAN, a dash and digits, not preceded by a word
# character: uppercase at any length, any case at three digits or more, so the
# lowercase branch and scope spelling is caught while a plan revision folder
# (one digit) is not. The Playwright tree runs strict: no revision folder lives
# there, and a test title is where a lowercase short id gets copied.
# shellcheck disable=SC2016 # an awk program: its $ fields are awk's, not the shell's
_MACHINE_LOCAL_REF_AWK='
function placeholder(segment,   index_position) {
  if (segment ~ /NNN/ || index(segment, "...")) return 1
  for (index_position = 1; index_position <= length(markers); index_position++)
    if (index(segment, substr(markers, index_position, 1))) return 1
  return 0
}
function report(match_text) {
  if (mode == "text" || mode == "message") printf "line %d: %s\n", line_number, match_text
  else printf "%s:%d: %s\n", current_path, line_number, match_text
}
function refused_path(token,   rest, parts, count, part_index) {
  if (token ~ /[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]/) return 1
  if (token ~ /^\.notebook\/(specs|plans|research|archive)\//) {
    rest = token
    sub(/^\.notebook\/[a-z]+\//, "", rest)
    split(rest, parts, "/")
    return (parts[1] != "" && !placeholder(parts[1]))
  }
  if (token ~ /^\.gaia\/local\/runs\//) {
    rest = token
    sub(/^\.gaia\/local\/runs\//, "", rest)
    count = split(rest, parts, "/")
    for (part_index = 1; part_index <= count; part_index++)
      if (parts[part_index] ~ /[0-9]/ && !placeholder(parts[part_index])) return 1
  }
  return 0
}
function boundary(line, start) {
  return start == 1 || substr(line, start - 1, 1) !~ /[A-Za-z0-9_]/
}
function scan(line,   lowered, offset, start, found, digits, rest, length_found, token) {
  lowered = tolower(line)
  offset = 0
  while (match(substr(lowered, offset + 1), /(spec|uat|plan)-[0-9]+/)) {
    start = offset + RSTART
    length_found = RLENGTH
    found = substr(line, start, length_found)
    if (boundary(line, start)) {
      digits = found
      sub(/^[A-Za-z]+-/, "", digits)
      if (strict || found ~ /^(SPEC|UAT|PLAN)-/ || length(digits) >= 3) report(found)
    }
    offset = start + length_found - 1
  }
  offset = 0
  while (match(substr(line, offset + 1), /\.(notebook|gaia\/local)\//)) {
    start = offset + RSTART
    rest = substr(line, start)
    match(rest, /^[^ \t`'"'"'"()|;]+/)
    token = substr(rest, 1, RLENGTH)
    offset = start + RLENGTH - 1
    sub(/[.,:;!?]+$/, "", token)
    if (boundary(line, start) && refused_path(token)) report(token)
  }
}
function comment_line(line) {
  if (style == "prose") return 1
  if ((style == "hash" || style == "both") && line ~ /^[ \t]*#/) return 1
  if ((style == "slash" || style == "both") && line ~ /^[ \t]*(\/\/|\/\*|\*)/) return 1
  return 0
}
BEGIN { markers = "<>{}$*[]\\" }
mode == "text" { line_number = NR; scan($0); next }
mode == "message" {
  line_number = NR
  if (finished) next
  if (index($0, "# ------------------------ >8 ------------------------") == 1) { finished = 1; next }
  if ($0 ~ /^#/) next
  if ($0 ~ /^Merge (branch|branches|pull request|remote-tracking branch|tag|commit) /) next
  if ($0 ~ /^Revert "/ || $0 ~ /^This reverts commit /) next
  scan($0)
  next
}
mode == "file" {
  if (FNR == 1) current_path = FILENAME
  line_number = FNR
  if (comment_line($0)) scan($0)
  next
}
mode == "diff" {
  if (substr($0, 1, 1) == "\001") {
    split(substr($0, 2), header, "\t")
    style = header[1]
    current_path = substr($0, length(style) + 3)
    in_header = 1
    next
  }
  if ($0 ~ /^@@ /) {
    match($0, /\+[0-9]+/)
    line_number = substr($0, RSTART + 1, RLENGTH - 1) + 0
    in_header = 0
    next
  }
  if (in_header) next
  if (substr($0, 1, 1) == "+") {
    if (comment_line(substr($0, 2))) scan(substr($0, 2))
    line_number++
  }
  next
}
'

# Scan whole files, every line, one `<path>:<line>: <match>` per hit with each
# path as given; $1 is strict (1 or 0). Always returns 0 when awk ran.
machine_local_ref_files() {
  local strict="$1"
  shift
  awk -v mode=file -v style=prose -v strict="$strict" "$_MACHINE_LOCAL_REF_AWK" "$@"
}

# Set MACHINE_LOCAL_REF_STYLE to which lines of a tracked path are read: prose
# (every line), hash or slash (full-line comments in that syntax), both, or
# skip. A variable, not output: the tracked walk calls it once per file, and a
# command substitution forks each time.
machine_local_ref_style() {
  local path="$1"
  MACHINE_LOCAL_REF_STYLE="skip"
  case "/$path" in
    */tests/* | */test/* | */__tests__/* | */fixtures/* | */.playwright/*) return ;;
  esac
  case "${path##*/}" in
    *.test.* | *.spec.* | *.bats | *.snap) return ;;
  esac
  case "$path" in
    *.md | *.mdx) MACHINE_LOCAL_REF_STYLE="prose" ;;
    *.sh | *.bash | *.yml | *.yaml | .githooks/*) MACHINE_LOCAL_REF_STYLE="hash" ;;
    *.ts | *.tsx | *.js | *.jsx | *.mjs | *.cjs | *.css) MACHINE_LOCAL_REF_STYLE="slash" ;;
    *.tmpl) MACHINE_LOCAL_REF_STYLE="both" ;;
  esac
}

machine_local_ref_explain() {
  cat <<'EXPLAIN'
A machine-local reference names a document that exists on one machine only: a
SPEC, UAT or plan number, or a concrete path under .notebook/ or .gaia/local/.
Nobody else can open it, so write out what the reference means instead: the
behavior, decision or evidence it stood for. A placeholder passes (SPEC-NNN, a
<date>-<topic> folder), and so does a state location GAIA owns on every
machine (.gaia/local/runs/<branch>/STATE.md).
Rule: .claude/rules/working-doc-ids.md
EXPLAIN
}

# Scan a file (or - for stdin) line by line.
machine_local_ref_text() {
  local input="$1" mode="${2:-text}"
  if [ "$input" != "-" ] && [ ! -r "$input" ]; then
    printf 'machine-local-ref-lib.sh: cannot read: %s\n' "$input" >&2
    return 2
  fi
  local hits
  hits=$(awk -v mode="$mode" "$_MACHINE_LOCAL_REF_AWK" "$input") || return 2
  [ -z "$hits" ] && return 0
  printf '%s\n' "$hits"
  return 1
}

_machine_local_ref_root() {
  local root="$1"
  if [ -z "$root" ] || ! git -C "$root" rev-parse --show-toplevel 2>/dev/null; then
    printf 'machine-local-ref-lib.sh: not a git work tree: %s\n' "$root" >&2
    return 2
  fi
}

# Scan the lines the staged change adds. A merge, cherry-pick or revert being
# concluded carries lines another commit already wrote, so it is not scanned.
machine_local_ref_staged() {
  local root git_directory pending path previous_path change_status hits
  root=$(_machine_local_ref_root "$1") || return 2
  git_directory=$(git -C "$root" rev-parse --absolute-git-dir) || return 2
  for pending in MERGE_HEAD CHERRY_PICK_HEAD REVERT_HEAD; do
    [ -e "$git_directory/$pending" ] && return 0
  done
  hits=$(
    git -C "$root" diff --cached --name-status -z -M --diff-filter=ACMR |
      while IFS= read -r -d '' change_status; do
        IFS= read -r -d '' path
        previous_path=""
        if [ "${change_status#R}" != "$change_status" ]; then
          previous_path="$path"
          IFS= read -r -d '' path
        fi
        machine_local_ref_style "$path"
        [ "$MACHINE_LOCAL_REF_STYLE" = "skip" ] && continue
        printf '\001%s\t%s\n' "$MACHINE_LOCAL_REF_STYLE" "$path"
        # A rename is diffed with both sides named so git pairs them and only
        # the lines it really changed arrive as additions.
        if [ -n "$previous_path" ]; then
          git --literal-pathspecs -C "$root" diff --cached -M -U0 --no-color --no-ext-diff --no-textconv -- "$previous_path" "$path"
        else
          git --literal-pathspecs -C "$root" diff --cached -U0 --no-color --no-ext-diff --no-textconv -- "$path"
        fi
      done | awk -v mode=diff "$_MACHINE_LOCAL_REF_AWK"
  ) || return 2
  [ -z "$hits" ] && return 0
  printf '%s\n' "$hits"
  return 1
}

# Scan one style's batch of paths, relative to the root so hits print them as
# tracked.
_machine_local_ref_batch() {
  local root="$1" style="$2"
  shift 2
  (cd "$root" && printf '%s\0' "$@" | xargs -0 awk -v mode=file -v style="$style" "$_MACHINE_LOCAL_REF_AWK")
}

# Scan every tracked file whole, grouped by style so awk runs once per batch.
machine_local_ref_tracked() {
  local root path hits
  root=$(_machine_local_ref_root "$1") || return 2
  local prose=() hash=() slash=() both=()
  while IFS= read -r -d '' path; do
    machine_local_ref_style "$path"
    [ "$MACHINE_LOCAL_REF_STYLE" != "skip" ] && [ -f "$root/$path" ] && [ ! -L "$root/$path" ] || continue
    case "$MACHINE_LOCAL_REF_STYLE" in
      prose) prose+=("$path") ;;
      hash) hash+=("$path") ;;
      slash) slash+=("$path") ;;
      both) both+=("$path") ;;
    esac
  done < <(git -C "$root" ls-files -z)
  hits=$(
    if [ "${#prose[@]}" -gt 0 ]; then _machine_local_ref_batch "$root" prose "${prose[@]}" || exit 2; fi
    if [ "${#hash[@]}" -gt 0 ]; then _machine_local_ref_batch "$root" hash "${hash[@]}" || exit 2; fi
    if [ "${#slash[@]}" -gt 0 ]; then _machine_local_ref_batch "$root" slash "${slash[@]}" || exit 2; fi
    if [ "${#both[@]}" -gt 0 ]; then _machine_local_ref_batch "$root" both "${both[@]}" || exit 2; fi
  ) || return 2
  [ -z "$hits" ] && return 0
  printf '%s\n' "$hits"
  return 1
}

# The git hooks' one call: run the message or staged scan and, on a hit, print
# it with what to do. Returns 1 on a hit and on a scan that could not run, so a
# hook that refuses on any non-zero fails closed.
machine_local_ref_check() {
  local verb="$1" target="$2" subject refusal hits status
  case "$verb" in
    message) subject="The commit message" refusal="The commit message cites" ;;
    staged) subject="Staged lines" refusal="Staged lines cite" ;;
    *)
      printf 'usage: machine-local-ref-lib.sh check message|staged <file|root>\n' >&2
      return 2
      ;;
  esac
  if [ "$verb" = message ]; then
    hits=$(machine_local_ref_text "$target" message 2>&1) && status=0 || status=$?
  else
    hits=$(machine_local_ref_staged "$target" 2>&1) && status=0 || status=$?
  fi
  [ "$status" -eq 0 ] && return 0
  if [ "$status" -eq 1 ]; then
    printf '\033[31m✖ %s a machine-local reference:\033[0m\n' "$refusal"
    printf '%s\n' "$hits"
    machine_local_ref_explain
  else
    printf '\033[31m✖ %s: could not scan for machine-local references:\033[0m\n' "$subject"
    printf '%s\n' "$hits"
  fi
  return 1
}

_machine_local_ref_main() {
  set -uo pipefail
  local verb="${1:-}"
  case "$verb" in
    check)
      [ "$#" -eq 3 ] || {
        printf 'usage: machine-local-ref-lib.sh check message|staged <file|root>\n' >&2
        return 2
      }
      machine_local_ref_check "$2" "$3"
      ;;
    text | message)
      [ "$#" -eq 2 ] || {
        printf 'usage: machine-local-ref-lib.sh %s <file>\n' "$verb" >&2
        return 2
      }
      machine_local_ref_text "$2" "$verb"
      ;;
    staged | tracked)
      [ "$#" -eq 2 ] || {
        printf 'usage: machine-local-ref-lib.sh %s <root>\n' "$verb" >&2
        return 2
      }
      "machine_local_ref_$verb" "$2"
      ;;
    explain) machine_local_ref_explain ;;
    *)
      printf 'usage: machine-local-ref-lib.sh text|message|staged|tracked|check|explain\n' >&2
      return 2
      ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  _machine_local_ref_main "$@"
  exit $?
fi
