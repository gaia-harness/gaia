# shellcheck shell=bash
#
# Sourced by uat-lib.sh, never executed. Helpers that keep uat-lib.sh under
# its line limit: uat_lib_code_only, which reads a rendered test as code alone,
# the route-row and Playwright-row validation arms of uat_lib_validate_routing,
# the surface normalizer, and the frontend
# package lookup behind the directory helpers.
#
# Bash 3.2 compatible; BSD and GNU tools.

# Prints the file with comment text and the contents of string and template
# literals replaced by spaces, so a pattern scan sees code only. Line count and
# column positions are preserved (the quote characters themselves stay). Honest
# limit: a character state machine, not a parser, so an expression inside a
# template literal (`${...}`) is blanked with the rest of the literal, and a
# regular expression literal that holds a quote or a comment opener can
# confuse the state.
uat_lib_code_only() {
  local file="${1:-}"
  [ -f "$file" ] || return 1
  LC_ALL=C awk '
    BEGIN { state = "code" }
    {
      line = $0
      length_of_line = length(line)
      output = ""
      position = 1
      while (position <= length_of_line) {
        character = substr(line, position, 1)
        next_character = substr(line, position + 1, 1)
        if (state == "code") {
          if (character == "/" && next_character == "/") { state = "line"; output = output "  "; position += 2; continue }
          if (character == "/" && next_character == "*") { state = "block"; output = output "  "; position += 2; continue }
          if (character == "\047") state = "single"
          else if (character == "\"") state = "double"
          else if (character == "`") state = "template"
          output = output character
          position++
        } else if (state == "line") {
          output = output " "
          position++
        } else if (state == "block") {
          if (character == "*" && next_character == "/") { state = "code"; output = output "  "; position += 2; continue }
          output = output " "
          position++
        } else {
          closer = state == "single" ? "\047" : (state == "double" ? "\"" : "`")
          if (character == "\\") { output = output (next_character == "" ? " " : "  "); position += 2; continue }
          if (character == closer) { state = "code"; output = output character; position++; continue }
          output = output " "
          position++
        }
      }
      # A line comment and an unterminated quoted string end with their line.
      if (state == "line" || state == "single" || state == "double") state = "code"
      print output
    }
  ' "$file"
}

# One route row's refusals, each one `uat-routing:` line on stderr. Prints the
# number of problems found to stdout. Arguments: uat_id, feature_folder,
# file_name, the newline-joined paths other route rows already claim.
uat_lib_route_row_problems() {
  local uat_id="$1" feature_folder="$2" file_name="$3" claimed_paths="$4"
  local problems=0 kebab_segment='[a-z0-9]+(-[a-z0-9]+)*'
  if ! [[ "$feature_folder" =~ ^$kebab_segment(/$kebab_segment)*$ ]]; then
    printf "uat-routing: %s is route with feature_folder '%s'; expected kebab-case segments\n" "$uat_id" "$feature_folder" >&2
    problems=$((problems + 1))
  fi
  if [[ "/$feature_folder/" == */hooks/* ]]; then
    printf "uat-routing: %s is route with feature_folder '%s'; a hooks segment would leave the Vitest node project\n" "$uat_id" "$feature_folder" >&2
    problems=$((problems + 1))
  fi
  # A .server test, not .spec: lint limits a .server import to *.server.test.* files.
  if ! [[ "$file_name" =~ ^$kebab_segment(\.server)?\.test\.ts$ ]]; then
    printf "uat-routing: %s is route with file_name '%s'; expected a kebab-case name ending .test.ts or .server.test.ts\n" "$uat_id" "$file_name" >&2
    problems=$((problems + 1))
  fi
  if grep -qiE '(spec|uat|plan)-[0-9]' <<<"$feature_folder/$file_name"; then
    printf "uat-routing: %s's feature_folder or file_name carries a working-document id; name the behavior instead\n" "$uat_id" >&2
    problems=$((problems + 1))
  fi
  if grep -qxF -- "$feature_folder/$file_name" <<<"$claimed_paths"; then
    printf 'uat-routing: %s resolves to %s/%s, a path another route row already claims\n' "$uat_id" "$feature_folder" "$file_name" >&2
    problems=$((problems + 1))
  fi
  printf '%s\n' "$problems"
}

# One real-server, browser or legacy e2e row's refusals, each one
# `uat-routing:` line on stderr; the surface name in a message is the row's own.
# Prints the number of problems to stdout. Arguments: surface, uat_id,
# feature_folder, file_name, the newline-joined paths any earlier real-server,
# browser or e2e row claims (one path space across the three surfaces).
uat_lib_playwright_row_problems() {
  local surface="$1" uat_id="$2" feature_folder="$3" file_name="$4" claimed_paths="$5"
  local problems=0 kebab_segment='[a-z0-9]+(-[a-z0-9]+)*'
  if ! [[ "$feature_folder" =~ ^$kebab_segment(/$kebab_segment)*$ ]]; then
    printf "uat-routing: %s is %s with feature_folder '%s'; expected kebab-case segments\n" "$uat_id" "$surface" "$feature_folder" >&2
    problems=$((problems + 1))
  fi
  if ! [[ "$file_name" =~ ^$kebab_segment\.spec\.ts$ ]]; then
    printf "uat-routing: %s is %s with file_name '%s'; expected a kebab-case name ending .spec.ts\n" "$uat_id" "$surface" "$file_name" >&2
    problems=$((problems + 1))
  fi
  if grep -qiE '(spec|uat|plan)-[0-9]' <<<"$feature_folder/$file_name"; then
    printf "uat-routing: %s's feature_folder or file_name carries a working-document id; name the behavior instead\n" "$uat_id" >&2
    problems=$((problems + 1))
  fi
  if grep -qxF -- "$feature_folder/$file_name" <<<"$claimed_paths"; then
    printf 'uat-routing: %s resolves to %s/%s, a path another real-server, browser or e2e row already claims\n' "$uat_id" "$feature_folder" "$file_name" >&2
    problems=$((problems + 1))
  fi
  printf '%s\n' "$problems"
}

# Prints the Playwright surface a routing surface names: real-server for
# real-server, browser for browser or the legacy e2e. Prints nothing and
# returns 1 for any other surface. The one place a legacy e2e row reads as browser.
uat_lib_playwright_surface() {
  case "${1:-}" in
    real-server) printf 'real-server\n' ;;
    browser | e2e) printf 'browser\n' ;;
    *) return 1 ;;
  esac
}

# Prints a subdirectory of the web package, bare for package path `.`.
_uat_lib_web_subdirectory() {
  local package_path
  package_path=$(_uat_lib_web_package_path "${1:-}") || return 1
  if [ "$package_path" = "." ]; then
    printf '%s\n' "$2"
  else
    printf '%s\n' "$package_path/$2"
  fi
}

_uat_lib_web_package_path() {
  local repo_root="${1:-}" packages_library packages_status=0 members member_count
  local member_path
  packages_library="$_UAT_LIB_DIRECTORY/../../../.claude/hooks/lib/gaia-packages.sh"
  if [ ! -f "$packages_library" ]; then
    printf 'package library missing: %s. Next step: restore it from the GAIA release.\n' "$packages_library" >&2
    return 1
  fi
  # shellcheck disable=SC1090
  source "$packages_library"
  gaia_packages_load "$repo_root" || packages_status=$?
  if [ "$packages_status" -ne 0 ]; then
    printf '%s\n' "$GAIA_PACKAGES_ERROR" >&2
    return 1
  fi
  members=$(gaia_packages_web_members)
  if [ -z "$members" ]; then
    printf '%s\n' 'gaia-packages: no registered package declares "stack": "web". Next step: add "stack": "web" to the app package'"'"'s gaia.package.json, which .gaia/packages.json registers.' >&2
    return 1
  fi
  member_count=$(grep -c . <<<"$members")
  if [ "$member_count" -gt 1 ]; then
    printf 'gaia-packages: several packages declare the web stack (%s). Next step: leave one web member, since UAT files land in a single package.\n' "$(cut -f1 <<<"$members" | paste -sd, - | sed 's/,/, /g')" >&2
    return 1
  fi
  IFS=$'\t' read -r _ member_path <<<"$members"
  printf '%s\n' "$member_path"
}
