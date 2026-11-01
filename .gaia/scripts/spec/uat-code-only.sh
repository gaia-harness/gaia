# shellcheck shell=bash
#
# Sourced by uat-lib.sh, never executed. Helpers that keep uat-lib.sh under
# its line limit: uat_lib_code_only, which reads a rendered test as code alone,
# the route-row validation arm of uat_lib_validate_routing, and the frontend
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

# Prints a subdirectory of the frontend package, bare for package path `.`.
_uat_lib_frontend_subdirectory() {
  local package_path
  package_path=$(_uat_lib_frontend_package_path "${1:-}") || return 1
  if [ "$package_path" = "." ]; then
    printf '%s\n' "$2"
  else
    printf '%s\n' "$package_path/$2"
  fi
}

_uat_lib_frontend_package_path() {
  local repo_root="${1:-}" packages_library packages_status=0 package_path
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
  if ! package_path=$(gaia_package_dir frontend); then
    printf '%s\n' "gaia-packages: .gaia/packages.json registers no package named frontend. Next step: add a frontend entry, or delete the registry to use the built-in default." >&2
    return 1
  fi
  printf '%s\n' "$package_path"
}
