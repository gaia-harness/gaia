#!/usr/bin/env bash
# Enumerates the requirement-source keys a test-design table must cover, one
# per line, sorted:
#   flow:<slug>                           each SPEC flow
#   success_criteria:<i>                  0-based
#   scope_boundaries:<bucket>:<i>         bucket always|ask_first|never, 0-based
#   clarifications:<i>                    0-based index into `answered`
#   directive:<n>                         numbered item under the audit heading
#                                         that starts `## Plan-time directives`
#   description                           a spec-less plan's one key
#
# Usage:
#   requirement-keys.sh --spec <SPEC.md> [--audit <AUDIT.md>]
#   requirement-keys.sh --description
#
# Exit 0 ok, 2 usage, an unreadable file, or a SPEC with no frontmatter (or no
# parseable flows). Bash 3.2 compatible; BSD and GNU tools.

set -uo pipefail

SCRIPT_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=.gaia/scripts/spec/flows-lib.sh
source "$SCRIPT_DIRECTORY/flows-lib.sh"

usage() {
  printf 'usage: requirement-keys.sh --spec <SPEC.md> [--audit <AUDIT.md>] | --description\n' >&2
  exit 2
}

spec_path=''
audit_path=''
description_mode=0
while [ $# -gt 0 ]; do
  case "$1" in
    --spec) [ $# -ge 2 ] || usage; spec_path="$2"; shift 2 ;;
    --audit) [ $# -ge 2 ] || usage; audit_path="$2"; shift 2 ;;
    --description) description_mode=1; shift ;;
    *) usage ;;
  esac
done

if [ "$description_mode" -eq 1 ]; then
  if [ -n "$spec_path" ] || [ -n "$audit_path" ]; then usage; fi
  printf 'description\n'
  exit 0
fi
[ -n "$spec_path" ] || usage

if [ ! -r "$spec_path" ]; then
  printf 'requirement-keys: cannot read: %s\n' "$spec_path" >&2
  exit 2
fi
if [ -n "$audit_path" ] && [ ! -r "$audit_path" ]; then
  printf 'requirement-keys: cannot read: %s\n' "$audit_path" >&2
  exit 2
fi

frontmatter=$(_flows_lib_frontmatter "$spec_path") || {
  printf 'requirement-keys: SPEC has no frontmatter: %s\n' "$spec_path" >&2
  exit 2
}

flow_rows=$(flows_lib_parse_spec "$spec_path") || exit 2

list_keys() {
  printf '%s\n' "$flow_rows" | awk -F '\t' '{ print "flow:" $2 }'

  printf '%s\n' "$frontmatter" | awk '
    { line = $0; sub(/\r$/, "", line) }
    line ~ /^[ \t]*(#|$)/ { next }
    {
      match(line, /^ */)
      indent = RLENGTH
      body = substr(line, indent + 1)
    }
    indent == 0 && body ~ /^[A-Za-z_]+:/ {
      top = body
      sub(/:.*/, "", top)
      sub_key = ""
      item_indent = -1
      count = 0
      next
    }
    (top == "scope_boundaries" || top == "clarifications") && indent > 0 && body ~ /^[A-Za-z_]+:[ \t]*$/ {
      sub_key = body
      sub(/:.*/, "", sub_key)
      item_indent = -1
      count = 0
      next
    }
    body ~ /^- / {
      if (top == "success_criteria") {
        key_prefix = "success_criteria"
      } else if (top == "scope_boundaries" && (sub_key == "always" || sub_key == "ask_first" || sub_key == "never")) {
        key_prefix = "scope_boundaries:" sub_key
      } else if (top == "clarifications" && sub_key == "answered") {
        key_prefix = "clarifications"
      } else {
        next
      }
      if (item_indent < 0) item_indent = indent
      if (indent == item_indent) {
        print key_prefix ":" count
        count++
      }
    }
  '

  if [ -n "$audit_path" ]; then
    awk '
      { line = $0; sub(/\r$/, "", line) }
      line ~ /^## / { in_directives = (index(line, "## Plan-time directives") == 1); next }
      in_directives && line ~ /^[0-9]+\. / {
        number = line
        sub(/\..*/, "", number)
        print "directive:" number
      }
    ' "$audit_path"
  fi
}

list_keys | LC_ALL=C sort
