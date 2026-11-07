# shellcheck shell=bash
#
# Shared reader of SPEC flows and of a Playwright spec's @covers declaration.
# Sourced, never executed: several scripts call these functions by name, so
# before a rename or a changed output shape, grep the tree for the function name
# (git grep -n flows_lib_).
#
# Every function writes data to stdout and diagnostics to stderr. Status 2 means
# invalid input. Status 1 is an operational failure, except for the predicates:
# flows_lib_covers_paths returns 1 when there is no declaration and
# flows_lib_carries_working_document_id returns 1 when there is no id. No
# `set -e` here: callers own their shell options.
#
# A SPEC flow field is canonicalized by flows_lib_canonical_text (fold
# continuation lines, strip one layer of YAML quotes, normalize whitespace);
# already-canonical text goes through flows_lib_whitespace_text only, because
# quote stripping is not idempotent.
#
# Bash 3.2 compatible; BSD and GNU tools. User text never reaches awk through
# `-v` (which processes backslash escapes): it arrives on stdin or as a file
# operand.

if [ -n "${FLOWS_LIB_SH:-}" ]; then
  return 0
fi
FLOWS_LIB_SH=1

_FLOWS_LIB_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=.gaia/scripts/machine-local-ref-lib.sh
source "$_FLOWS_LIB_DIRECTORY/../machine-local-ref-lib.sh"

flows_lib_whitespace_text() {
  local text
  text=$(LC_ALL=C tr -d '\000' | LC_ALL=C tr '\t\r\n' '   ' | LC_ALL=C tr -s ' ')
  text="${text# }"
  text="${text% }"
  printf '%s' "$text"
}

flows_lib_canonical_text() {
  LC_ALL=C tr -d '\000' | LC_ALL=C awk '
    NR == 1 { value = $0; next }
    {
      line = $0
      sub(/^[ \t]+/, "", line)
      value = value " " line
    }
    END {
      sub(/^[ \t\r\n]+/, "", value)
      sub(/[ \t\r\n]+$/, "", value)
      length_of_value = length(value)
      first = substr(value, 1, 1)
      last = substr(value, length_of_value, 1)
      if (length_of_value >= 2 && first == "\"" && last == "\"") {
        inner = substr(value, 2, length_of_value - 2)
        value = ""
        position = 1
        inner_length = length(inner)
        while (position <= inner_length) {
          character = substr(inner, position, 1)
          if (character == "\\" && position < inner_length) {
            following = substr(inner, position + 1, 1)
            if (following == "\\" || following == "\"") {
              value = value following
              position += 2
              continue
            }
          }
          value = value character
          position++
        }
      } else if (length_of_value >= 2 && first == "\047" && last == "\047") {
        inner = substr(value, 2, length_of_value - 2)
        value = ""
        while ((at = index(inner, "\047\047")) > 0) {
          value = value substr(inner, 1, at)
          inner = substr(inner, at + 2)
        }
        value = value inner
      }
      printf "%s", value
    }
  ' | flows_lib_whitespace_text
}

# Status 0 when the text carries a working-document id; the detector owns which.
flows_lib_carries_working_document_id() {
  local hits
  hits=$(machine_local_ref_text - text <<<"${1:-}" 2>/dev/null)
  [ -n "$hits" ]
}

# Prints the frontmatter between the first two `---` lines; status 2 when the
# block never closes.
_flows_lib_frontmatter() {
  awk '
    {
      line = $0
      sub(/\r$/, "", line)
    }
    state == 0 && line == "---" { state = 1; next }
    state == 1 && line == "---" { state = 2; exit }
    state == 1 { print }
    END { if (state != 2) exit 2 }
  ' "$1"
}

# Splits the flows block into tagged records, one per line:
#   N                      a new list item
#   K<TAB>key<TAB>value    a key line of the current item
#   C<TAB>key<TAB>text     a continuation line of the key above it
#   L<TAB>key<TAB>text     a block list entry under the key above it
_flows_lib_records() {
  awk '
    function trim(text) {
      sub(/^[ \t]+/, "", text)
      sub(/[ \t]+$/, "", text)
      return text
    }
    {
      line = $0
      sub(/\r$/, "", line)
      gsub(/\t/, " ", line)
    }
    /^flows:/ { capture = 1; next }
    capture && line ~ /^[A-Za-z_][A-Za-z0-9_]*:/ { capture = 0 }
    !capture { next }
    line ~ /^[ \t]*$/ || line ~ /^[ \t]*#/ { next }
    {
      match(line, /^ */)
      indent = RLENGTH
      current_line = line
      if (current_line ~ /^ *-( +|$)/) {
        if (item_indent == "") item_indent = indent
        sub(/^ *- */, "", current_line)
        if (indent <= item_indent) {
          print "N"
          current = ""
        } else {
          print "L\t" current "\t" trim(current_line)
          next
        }
      } else if (current_line !~ /^ +[A-Za-z_][A-Za-z0-9_]*:( |$)/) {
        if (current != "") print "C\t" current "\t" trim(current_line)
        next
      }
      current_line = trim(current_line)
      if (current_line ~ /^[A-Za-z_][A-Za-z0-9_]*:( |$)/) {
        key = current_line
        sub(/:.*/, "", key)
        value = current_line
        sub(/^[A-Za-z0-9_]+: */, "", value)
        print "K\t" key "\t" value
        current = key
      } else {
        current = ""
      }
    }
  ' <<<"$1"
}

# Prints `F<TAB>code<TAB>message<TAB>location` per finding and `R<TAB>row` per
# valid flow. Status 2 only for an unreadable file or unclosed frontmatter.
_flows_lib_analyze() {
  local spec_path="${1:-}" frontmatter records record tag rest key value
  local problems=0 item_open=0 ordinal=0 seen_ids=''
  local it_flow_id='' it_slug='' it_name='' it_why='' it_test_path=''
  local it_covers_present=0 it_covers_inline='' it_covers_list='' it_forbidden=''

  if [ ! -f "$spec_path" ] || ! frontmatter=$(_flows_lib_frontmatter "$spec_path"); then
    printf "flows-lib: SPEC missing or its frontmatter has no closing '---': %s\n" "$spec_path" >&2
    return 2
  fi

  if grep -q '^uats:' <<<"$frontmatter"; then
    printf 'F\tuats_key_present\t%s\t%s\n' 'the SPEC carries a top-level uats: key; replace it with flows:' 'frontmatter.uats'
  fi
  if ! grep -q '^flows:' <<<"$frontmatter"; then
    printf 'F\tmissing_flows\t%s\t%s\n' 'the SPEC has no flows: key' 'frontmatter.flows'
    return 0
  fi

  finding() {
    printf 'F\t%s\t%s\tfrontmatter.flows.%s\n' "$1" "$2" "$3"
    problems=$((problems + 1))
  }

  _flows_lib_flush_item() {
    [ "$item_open" -eq 1 ] || return 0
    local flow_id slug name why test_path label kind target
    local covers_paths='' path_text path_line forbidden_key
    ordinal=$((ordinal + 1))
    problems=0
    flow_id=$(printf '%s' "$it_flow_id" | flows_lib_canonical_text)
    slug=$(printf '%s' "$it_slug" | flows_lib_canonical_text)
    name=$(printf '%s' "$it_name" | flows_lib_canonical_text)
    why=$(printf '%s' "$it_why" | flows_lib_canonical_text)
    test_path=$(printf '%s' "$it_test_path" | flows_lib_canonical_text)
    label="${flow_id:-#$ordinal}"

    [ -n "$flow_id" ] || finding flow_missing_field "flow $label has no flow_id" "$label.flow_id"
    [ -n "$slug" ] || finding flow_missing_field "flow $label has no slug" "$label.slug"
    [ -n "$name" ] || finding flow_missing_field "flow $label has no name" "$label.name"
    [ -n "$why" ] || finding flow_missing_field "flow $label has no why" "$label.why"
    if [ -n "$flow_id" ]; then
      [[ "$flow_id" =~ ^FLOW-[0-9]{3,}$ ]] || finding bad_flow_id "flow_id '$flow_id' must match FLOW-NNN (three or more digits)" "$label.flow_id"
      ! grep -qxF -- "$flow_id" <<<"$seen_ids" || finding duplicate_flow_id "flow_id $flow_id appears more than once" "$label.flow_id"
      seen_ids="$seen_ids$flow_id"$'\n'
    fi
    [ -z "$slug" ] || [[ "$slug" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]] || finding bad_slug "slug '$slug' must be kebab-case" "$label.slug"

    if [ "$it_covers_present" -eq 1 ]; then
      path_text=$(printf '%s' "$it_covers_inline" | flows_lib_canonical_text)
      path_text="${path_text#\[}"
      path_text="${path_text%\]}"
      while IFS= read -r path_line; do
        path_line=$(printf '%s' "$path_line" | flows_lib_canonical_text)
        [ -z "$path_line" ] || covers_paths="${covers_paths:+$covers_paths }$path_line"
      done < <(printf '%s\n%s\n' "$path_text" "$it_covers_list" | tr ',' '\n')
    fi
    if [ "$it_covers_present" -eq 1 ] && [ -z "$covers_paths" ]; then
      finding flow_target_conflict "flow $label has an empty covers list" "$label.covers"
    elif [ "$it_covers_present" -eq 1 ] && [ -n "$test_path" ]; then
      finding flow_target_conflict "flow $label has both covers and test_path; keep exactly one" "$label.covers"
    elif [ "$it_covers_present" -eq 0 ] && [ -z "$test_path" ]; then
      finding flow_target_conflict "flow $label has neither covers nor test_path; it needs exactly one" "$label"
    fi

    for forbidden_key in $it_forbidden; do
      finding given_when_then_field "flow $label has a $forbidden_key field; a flow is one line, not a Given/When/Then" "$label.$forbidden_key"
    done
    ! flows_lib_carries_working_document_id "$name" || finding working_document_id "flow $label name carries a working-document id; write the behavior it stood for" "$label.name"
    ! flows_lib_carries_working_document_id "$why" || finding working_document_id "flow $label why carries a working-document id; write the behavior it stood for" "$label.why"

    if [ "$problems" -eq 0 ]; then
      kind='command'
      target="$test_path"
      if [ "$it_covers_present" -eq 1 ]; then
        kind=web
        target="$covers_paths"
      fi
      printf 'R\t%s\t%s\t%s\t%s\t%s\t%s\n' "$flow_id" "$slug" "$name" "$why" "$kind" "$target"
    fi
  }

  records=$(_flows_lib_records "$frontmatter")
  while IFS= read -r record; do
    [ -n "$record" ] || continue
    tag="${record%%$'\t'*}"
    rest="${record#*$'\t'}"
    case "$tag" in
      N)
        _flows_lib_flush_item
        item_open=1
        it_flow_id='' it_slug='' it_name='' it_why='' it_test_path=''
        it_covers_present=0 it_covers_inline='' it_covers_list='' it_forbidden=''
        ;;
      K | C | L)
        [ "$item_open" -eq 1 ] || continue
        key="${rest%%$'\t'*}"
        value="${rest#*$'\t'}"
        if [ "$tag" = "K" ]; then
          case "$key" in
            covers) it_covers_present=1 ;;
            given | when | then) it_forbidden="$it_forbidden $key" ;;
          esac
        fi
        case "$key:$tag" in
          covers:K) it_covers_inline="$value" ;;
          covers:L) it_covers_list="${it_covers_list:+$it_covers_list$'\n'}$value" ;;
          flow_id:*) it_flow_id="${it_flow_id:+$it_flow_id$'\n'}$value" ;;
          slug:*) it_slug="${it_slug:+$it_slug$'\n'}$value" ;;
          name:*) it_name="${it_name:+$it_name$'\n'}$value" ;;
          why:*) it_why="${it_why:+$it_why$'\n'}$value" ;;
          test_path:*) it_test_path="${it_test_path:+$it_test_path$'\n'}$value" ;;
        esac
        ;;
    esac
  done <<<"$records"
  _flows_lib_flush_item
  unset -f _flows_lib_flush_item

  if [ "$ordinal" -eq 0 ]; then
    printf 'F\tmissing_flows\t%s\t%s\n' "the flows: list is empty" 'frontmatter.flows'
  fi
}

flows_lib_validate_spec() {
  local analysis status=0
  analysis=$(_flows_lib_analyze "${1:-}") || status=$?
  [ "$status" -eq 0 ] || return 2
  grep "^F$(printf '\t')" <<<"$analysis" | cut -f2- || true
  return 0
}

flows_lib_parse_spec() {
  local spec_path="${1:-}" analysis status=0 findings rows count first more=''
  analysis=$(_flows_lib_analyze "$spec_path") || status=$?
  [ "$status" -eq 0 ] || return 2
  findings=$(grep "^F$(printf '\t')" <<<"$analysis" || true)
  if [ -n "$findings" ]; then
    count=$(grep -c . <<<"$findings")
    first=$(head -n 1 <<<"$findings" | cut -f3)
    [ "$count" -le 1 ] || more=" (and $((count - 1)) more)"
    printf 'flows-lib: %s in %s%s\n' "$first" "$spec_path" "$more" >&2
    return 2
  fi
  rows=$(grep "^R$(printf '\t')" <<<"$analysis" | cut -f2- || true)
  if [ -z "$rows" ]; then
    printf 'flows-lib: no parseable flow in the flows: block of %s\n' "$spec_path" >&2
    return 2
  fi
  printf '%s\n' "$rows"
}

# Prints the path of every `// @covers <path> [<path> ...]` line in the file's
# leading comment block (every line before the first one that is neither blank
# nor a comment), one per line, in file order. Status 1 when there is none.
flows_lib_covers_paths() {
  local test_file="${1:-}"
  if [ ! -r "$test_file" ]; then
    printf 'flows-lib: cannot read: %s\n' "$test_file" >&2
    return 1
  fi
  awk '
    {
      line = $0
      sub(/\r$/, "", line)
    }
    in_block {
      if (index(line, "*/") > 0) {
        in_block = 0
        line = substr(line, index(line, "*/") + 2)
        if (line ~ /^[ \t]*$/) next
      } else next
    }
    line ~ /^[ \t]*$/ { next }
    line ~ /^[ \t]*\/\// {
      if (line ~ /^[ \t]*\/\/[ \t]*@covers([ \t]|$)/) {
        sub(/^[ \t]*\/\/[ \t]*@covers[ \t]*/, "", line)
        count = split(line, parts, /[ \t]+/)
        for (index_of_part = 1; index_of_part <= count; index_of_part++)
          if (parts[index_of_part] != "") { print parts[index_of_part]; found = 1 }
      }
      next
    }
    line ~ /^[ \t]*\/\*/ {
      rest = substr(line, index(line, "/*") + 2)
      if (index(rest, "*/") == 0) in_block = 1
      next
    }
    { exit }
    END { exit (found ? 0 : 1) }
  ' "$test_file"
}

flows_lib_web_package_path() {
  local repo_root="${1:-}" packages_library packages_status=0 members member_count
  local member_path
  packages_library="$_FLOWS_LIB_DIRECTORY/../../../.claude/hooks/lib/gaia-packages.sh"
  [ -f "$packages_library" ] || {
    printf 'package library missing: %s. Next step: restore it from the GAIA release.\n' "$packages_library" >&2
    return 1
  }
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
    printf 'gaia-packages: several packages declare the web stack (%s). Next step: leave one web member, since flow tests land in a single package.\n' "$(cut -f1 <<<"$members" | paste -sd, - | sed 's/,/, /g')" >&2
    return 1
  fi
  IFS=$'\t' read -r _ member_path <<<"$members"
  printf '%s\n' "$member_path"
}

# Prints a subdirectory of the web package, bare for package path `.`.
flows_lib_web_subdirectory() {
  local package_path
  package_path=$(flows_lib_web_package_path "${1:-}") || return 1
  if [ "$package_path" = "." ]; then
    printf '%s\n' "$2"
  else
    printf '%s\n' "$package_path/$2"
  fi
}
