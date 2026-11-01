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
