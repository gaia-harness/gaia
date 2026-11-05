# shellcheck shell=bash
#
# Sourced by uat-gate.sh, never executed. The static floor helpers shared by the
# e2e and route arms: they read a test file's text and need only
# uat_lib_code_only from the gate's own library.
#
# Bash 3.2 compatible; BSD and GNU tools.

# True when some expect( in the file has a first argument that is not a bare
# literal (true, false, null, undefined, a number, or a string without
# interpolation).
has_non_literal_expect() {
  awk '
    { text = text $0 "\n" }
    END {
      position = 1
      while ((offset = index(substr(text, position), "expect(")) > 0) {
        start = position + offset - 1
        before = start > 1 ? substr(text, start - 1, 1) : " "
        position = start + 7
        if (before ~ /[A-Za-z0-9_$.]/) continue
        rest = substr(text, position)
        sub(/^[ \t\r\n]+/, "", rest)
        first = substr(rest, 1, 1)
        if (first == "\047" || first == "\"" || first == "`") {
          closing = 0
          for (index_of = 2; index_of <= length(rest); index_of++) {
            character = substr(rest, index_of, 1)
            if (character == "\\") { index_of++; continue }
            if (character == first) { closing = index_of; break }
          }
          literal = 0
          if (closing > 0) {
            body = substr(rest, 2, closing - 2)
            after = substr(rest, closing + 1)
            sub(/^[ \t\r\n]+/, "", after)
            next_character = substr(after, 1, 1)
            if ((next_character == "," || next_character == ")") && !(first == "`" && index(body, "${") > 0)) literal = 1
          }
          if (!literal) { found = 1; exit }
          continue
        }
        token = ""
        for (index_of = 1; index_of <= length(rest); index_of++) {
          character = substr(rest, index_of, 1)
          if (character == "," || character == ")") break
          token = token character
        }
        gsub(/[ \t\r\n]+$/, "", token)
        if (token ~ /^(true|false|null|undefined)$/ || token ~ /^-?[0-9][0-9._]*$/) continue
        found = 1
        exit
      }
      exit found ? 0 : 1
    }
  ' "${1:--}"
}

# True when the code-only text of the file calls page.<method>( or a request
# fixture: request.<verb>(, or request.newContext( together with a verb call on
# any receiver (how a separate API context satisfies it).
has_e2e_call() {
  local code verbs='(get|post|put|patch|delete|head|fetch)'
  code=$(uat_lib_code_only "$1") || return 1
  grep -qE 'page\.[A-Za-z_]+\(' <<<"$code" && return 0
  grep -qE "(^|[^A-Za-z0-9_\$])request\.$verbs\(" <<<"$code" && return 0
  grep -qE '(^|[^A-Za-z0-9_$])request\.newContext\(' <<<"$code" && grep -qE "\\.$verbs\(" <<<"$code"
}

# request_receiver_names <file>: one receiver name per line that a verb call
# may legitimately use as a request context. `request` itself; every name the
# first destructured parameter of some callback binds (a project request-context
# fixture such as the signed-in one); every variable the file assigns from
# request.newContext( or playwright.request.newContext(; and every const, let
# or var declared from awaiting a call to one of those destructured names
# (`const rita = await signIn(...)`, a fixture that returns a context). Read
# from the code-only text, never decided by a name suffix. A destructured
# page-backed fixture lands in the list too, but no verb call on it is a
# request call, so the no-page check refuses it, not this list.
# Limit: the awaited-fixture arm cannot see what the fixture returns. A fixture
# that makes the request itself returns a response, which has no verb method,
# so it stays refused; one returning a Map or Headers would pass on `.get(`.
# An imported helper is not a destructured name, so a context it returns does
# not count.
request_receiver_names() {
  local code flat fixtures fixture
  code=$(uat_lib_code_only "$1") || return 1
  flat=$(printf '%s' "$code" | tr '\n\r\t' '   ')
  printf '%s\n' request
  fixtures=$(printf '%s' "$flat" | grep -oE '\([[:space:]]*\{[^{}]*\}[[:space:]]*[,)]' | sed -E 's/^\([[:space:]]*\{//; s/\}[[:space:]]*[,)]$//' | tr ',' '\n' | sed -E 's/^[[:space:]]+//; s/[[:space:]]*=.*$//; s/^.*:[[:space:]]*//; s/[[:space:]]+$//' | grep -E '^[A-Za-z_$][A-Za-z0-9_$]*$')
  [ -z "$fixtures" ] || printf '%s\n' "$fixtures"
  printf '%s' "$flat" | grep -oE '[A-Za-z_$][A-Za-z0-9_$]*[[:space:]]*=[[:space:]]*(await[[:space:]]+)?(playwright\.)?request\.newContext\(' | sed -E 's/[[:space:]]*=.*$//'
  while IFS= read -r fixture; do
    [ -n "$fixture" ] || continue
    fixture=${fixture//\$/\\\$}
    printf '%s' "$flat" | grep -oE "(const|let|var)[[:space:]]+[A-Za-z_\$][A-Za-z0-9_\$]*[[:space:]]*=[[:space:]]*await[[:space:]]+$fixture\\(" | sed -E 's/^(const|let|var)[[:space:]]+//; s/[[:space:]]*=.*$//'
  done <<<"$fixtures"
  return 0
}

# True when the code-only text of a real-server test calls a verb on a request
# context (request_receiver_names). A page.<method>( call does not satisfy it.
has_request_call() {
  local code verbs='(get|post|put|patch|delete|head|fetch)' receiver
  code=$(uat_lib_code_only "$1") || return 1
  while IFS= read -r receiver; do
    [ -n "$receiver" ] || continue
    receiver=${receiver//\$/\\\$}
    grep -qE "(^|[^A-Za-z0-9_\$])$receiver\\.$verbs\\(" <<<"$code" && return 0
  done < <(request_receiver_names "$1")
  return 1
}

# gate_opens_page <file>: run the shared page-use detector (page-use.mjs, the
# one definition of "opens a page") over one real-server test. Returns 0 clean,
# 1 a use, 4 when the detector could not run, after naming the prerequisite.
gate_opens_page() {
  local detector_status
  if ! command -v node >/dev/null 2>&1; then
    printf 'uat-gate.sh: node is not on PATH, so the real-server no-page check cannot run. Prerequisites: Node and the typescript package in the repo'"'"'s dependencies. Next step: install them and retry.\n' >&2
    return 4
  fi
  node "$(dirname "${BASH_SOURCE[0]}")/page-use.mjs" "$1" >/dev/null 2>&1
  detector_status=$?
  case "$detector_status" in
    0) return 0 ;;
    1) return 1 ;;
    *)
      printf 'uat-gate.sh: the real-server no-page check could not run (page-use.mjs exited %s). Prerequisites: Node and the typescript package in the repo'"'"'s dependencies. Next step: install them and retry.\n' "$detector_status" >&2
      return 4
      ;;
  esac
}
