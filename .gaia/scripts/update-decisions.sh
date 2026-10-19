#!/usr/bin/env bash
# shellcheck shell=bash
#
# update-decisions.sh: the one reader and writer of the adopter-owned decision
# log (.gaia/update-decisions.json), so the /update-gaia skill never hand-edits
# the JSON.
#
#   bash .gaia/scripts/update-decisions.sh check|deferred|deferred-tags|record|reconcile|context ...
#
# Contract with callers (the update skill): every
# subcommand except `check` validates the file first and exits 1 with the same
# output `check` prints, so no caller acts on an invalid file. Tag fields reach
# download commands, so the validation insists on semver tags. The file is
# outside the manifest, so the merge walk never touches it.
#
# Output tokens are machine lines; the skill formats any sentence itself.
# Exit 0 ok, 1 invalid file or refused record, 2 usage error or missing jq.
#
# reconcile ends a deferred entry that a run resolved without a question: it
# is dropped when the tree file equals the latest copy, and otherwise rebased
# to a blend entry at --latest-tag so later runs stop downloading its old
# baseline bundle. An entry still open in the report is left alone.
#
# Entries stay sorted by (path, key) so a repeated run writes a byte-identical
# file; writes go to a temp file beside the target and `mv` over it.

NEXT_STEP_SUFFIX='or restore it with git checkout -- FILE, then re-run /update-gaia.'

usage() {
  echo "usage: update-decisions.sh check|deferred|deferred-tags --file <path>" >&2
  echo "       update-decisions.sh record --file <path> --path <p> [--key <k>] --decision <d> --tag <t> --baseline-tag <bt> [--reason <r>]" >&2
  echo "       update-decisions.sh reconcile --file <path> --tree <dir> --latest-dir <dir> --report <report.json> --latest-tag <tag>" >&2
  echo "       update-decisions.sh context --file <path> --path <p> [--key <k>]" >&2
  exit 2
}

command -v jq >/dev/null 2>&1 || { echo "update-decisions.sh needs jq on PATH" >&2; exit 2; }

# Prints the first problem in a slurped document, or an empty string. The
# marked regions are what the mutation cases in the suite remove to prove the
# matching case can fail.
read -r -d '' VALIDATE_PROGRAM <<'JQ'
def semver:
  type == "string" and test("^v[0-9]+\\.[0-9]+\\.[0-9]+(-[0-9A-Za-z.-]+)?$");
# SEMVER-DEF
def unsafe_path:
  type != "string" or . == "" or startswith("/") or contains("\\")
  or (explode | any(. < 32 or . == 127))
  or (split("/") | index("..") != null);
def entry_errors:
  .decisions | to_entries[] | (.key + 1) as $n | .value as $v
  | if ($v | type) != "object" then "entry \($n) is not an object"
    else
      first(
        (("path", "decision", "tag", "baselineTag") as $field
          | select(($v[$field] | type) != "string")
          | "entry \($n) is missing a string \($field)"),
        (select(($v.decision | IN("blend", "keep", "gaia", "deferred")) | not)
          | "entry \($n) has an unknown decision"),
        (select(($v.tag | semver) | not)
          | "entry \($n) has a tag that is not a semver tag like v2.0.4"),
        (select(($v.baselineTag | semver) | not)
          | "entry \($n) has a baselineTag that is not a semver tag like v2.0.4"),
        (select($v.path | unsafe_path)
          | "entry \($n) has a path that is empty, absolute, or holds a .. segment, a backslash or a control byte"),
        (select($v | has("key"))
          | select(($v.key | type) != "string" or $v.key == "")
          | "entry \($n) has a key that is empty or not a string"),
        empty
      )
    end;
def duplicate_errors:
  [.decisions[] | [.path, .key]] | group_by(.) | .[] | select(length > 1)
  | .[0] as $pair
  | "duplicate entry for path \($pair[0])"
    + (if $pair[1] != null then " key \($pair[1])" else "" end);
if length != 1 then "not valid JSON"
elif (.[0] | type) != "object" then "top level is not an object"
elif .[0].schemaVersion != 1 then "schemaVersion is missing or not 1"
elif (.[0].decisions | type) != "array" then "decisions is not an array"
else
  .[0] | first(
    entry_errors,
    # BEGIN-DUPLICATE-CHECK
    duplicate_errors,
    # END-DUPLICATE-CHECK
    empty
  ) // ""
end
JQ

# First problem in the document read from stdin; empty when valid.
validation_error() {
  local problem
  problem="$(jq -s -r "$VALIDATE_PROGRAM" 2>/dev/null)" || problem='not valid JSON'
  printf '%s' "$problem"
}

# Exits 1 with the pinned output when the file exists and is invalid.
require_valid_file() {
  local file="$1" problem
  [ -f "$file" ] || return 0
  problem="$(validation_error <"$file")"
  [ -z "$problem" ] && return 0
  printf 'DECISIONS_INVALID %s: %s\n' "$file" "$problem"
  printf 'Next step: fix %s %s\n' "$file" "${NEXT_STEP_SUFFIX//FILE/$file}"
  exit 1
}

# Writes the document on stdin to the target through a temp file beside it.
write_atomically() {
  local file="$1" directory temporary
  directory="$(dirname "$file")"
  mkdir -p "$directory" || return 1
  temporary="$(mktemp "$directory/.update-decisions.XXXXXX")" || return 1
  if ! jq '.' >"$temporary" || ! mv "$temporary" "$file"; then
    rm -f "$temporary"
    return 1
  fi
}

subcommand="${1:-}"
[ -n "$subcommand" ] || usage
shift

file='' target_path='' key='' has_key=0 decision='' tag='' baseline_tag='' reason='' has_reason=0
tree='' latest_dir='' report='' latest_tag=''
while [ "$#" -gt 0 ]; do
  [ "$#" -ge 2 ] || usage
  case "$1" in
    --file) file="$2" ;;
    --path) target_path="$2" ;;
    --key) key="$2"; has_key=1 ;;
    --decision) decision="$2" ;;
    --tag) tag="$2" ;;
    --baseline-tag) baseline_tag="$2" ;;
    --reason) reason="$2"; has_reason=1 ;;
    --tree) tree="$2" ;;
    --latest-dir) latest_dir="$2" ;;
    --report) report="$2" ;;
    --latest-tag) latest_tag="$2" ;;
    *) usage ;;
  esac
  shift 2
done
[ -n "$file" ] || usage

case "$subcommand" in
  check)
    if [ ! -f "$file" ]; then
      echo 'DECISIONS_ABSENT'
      exit 0
    fi
    require_valid_file "$file"
    printf 'DECISIONS_OK %s\n' "$(jq '.decisions | length' "$file")"
    ;;

  deferred)
    require_valid_file "$file"
    [ -f "$file" ] || exit 0
    jq -r '.decisions[] | select(.decision == "deferred")
      | "DEFERRED \(.baselineTag) \(.path)" + (if has("key") then " \(.key)" else "" end)' "$file"
    ;;

  deferred-tags)
    require_valid_file "$file"
    [ -f "$file" ] || exit 0
    jq -r '[.decisions[] | select(.decision == "deferred") | .baselineTag] | unique
      | map(capture("^v(?<major>[0-9]+)\\.(?<minor>[0-9]+)\\.(?<patch>[0-9]+)(-(?<pre>.*))?$") + {tag: .})
      | sort_by([(.major | tonumber), (.minor | tonumber), (.patch | tonumber),
                 (if .pre == null then 1 else 0 end), (.pre // "")])
      | .[].tag' "$file"
    ;;

  record)
    [ -n "$target_path" ] && [ -n "$decision" ] && [ -n "$tag" ] && [ -n "$baseline_tag" ] || usage
    require_valid_file "$file"
    new_entry="$(jq -n --arg path "$target_path" --arg key "$key" --argjson has_key "$has_key" \
      --arg decision "$decision" --arg tag "$tag" --arg baselineTag "$baseline_tag" \
      --arg reason "$reason" --argjson has_reason "$has_reason" \
      '{path: $path}
       + (if $has_key == 1 then {key: $key} else {} end)
       + {decision: $decision, tag: $tag, baselineTag: $baselineTag}
       + (if $has_reason == 1 then {reason: $reason} else {} end)')"
    problem="$(printf '{"schemaVersion":1,"decisions":[%s]}' "$new_entry" | validation_error)"
    if [ -n "$problem" ]; then
      printf 'RECORD_REFUSED %s\n' "$problem"
      exit 1
    fi
    if [ -f "$file" ]; then
      existing="$(cat "$file")"
    else
      existing='{"schemaVersion":1,"decisions":[]}'
    fi
    printf '%s' "$existing" | jq --argjson entry "$new_entry" '
      .decisions |= (map(select((.path == $entry.path and (.key // null) == ($entry.key // null)) | not))
                     + [$entry] | sort_by([.path, (.key // "")]))' \
      | write_atomically "$file" || { echo "could not write $file" >&2; exit 1; }
    if [ "$has_key" -eq 1 ]; then
      printf 'RECORDED %s#%s %s\n' "$target_path" "$key" "$decision"
    else
      printf 'RECORDED %s %s\n' "$target_path" "$decision"
    fi
    ;;

  reconcile)
    [ -n "$tree" ] && [ -n "$latest_dir" ] && [ -n "$report" ] && [ -n "$latest_tag" ] || usage
    printf '%s' "$latest_tag" | grep -Eq '^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$' || usage
    [ -f "$report" ] || { echo "report not found: $report" >&2; exit 2; }
    require_valid_file "$file"
    [ -f "$file" ] || exit 0
    drop_indexes=''
    rebase_indexes=''
    drop_lines=''
    tab="$(printf '\t')"
    while IFS="$tab" read -r index entry_path entry_has_key entry_decision entry_key; do
      [ -n "$index" ] || continue
      if [ "$entry_has_key" = '1' ]; then
        # An item matches by its own key or by section.key, since the report's
        # items carry the section separately.
        if jq -e --arg path "$entry_path" --arg key "$entry_key" '
             [.files[]? | select(.path == $path) | .fieldMerge.alreadyLatest[]?
              | (.key, (if .section then "\(.section).\(.key)" else empty end))]
             | index($key) != null' "$report" >/dev/null 2>&1; then
          drop_indexes="$drop_indexes$index
"
          drop_lines="$drop_lines
DROPPED $entry_path#$entry_key"
        # REBASE-KEY-BEGIN
        elif [ "$entry_decision" = 'deferred' ] && jq -e --arg path "$entry_path" --arg key "$entry_key" '
             [.files[]? | select(.path == $path) | .fieldMerge | (.applied, .keptRemoved, .removedUpstream)[]?
              | (.key, (if .section then "\(.section).\(.key)" else empty end))]
             | index($key) != null' "$report" >/dev/null 2>&1; then
          rebase_indexes="$rebase_indexes$index
"
          drop_lines="$drop_lines
REBASED $entry_path#$entry_key $latest_tag"
        # REBASE-KEY-END
        fi
      else
        tree_file="$tree/$entry_path"
        latest_file="$latest_dir/$entry_path"
        if { [ ! -e "$tree_file" ] && [ ! -e "$latest_file" ]; } \
          || { [ -f "$tree_file" ] && [ -f "$latest_file" ] && cmp -s "$tree_file" "$latest_file"; }; then
          drop_indexes="$drop_indexes$index
"
          drop_lines="$drop_lines
DROPPED $entry_path"
        # REBASE-FILE-BEGIN
        elif [ "$entry_decision" = 'deferred' ]; then
          # A path the run resolved without a question no longer needs its old
          # baseline bundle; an open, pending or unreported path stays put.
          path_status="$(jq -r --arg path "$entry_path" \
            '[.files[]? | select(.path == $path) | .status] | first // ""' "$report" 2>/dev/null)"
          case "$path_status" in
            '' | open | pending-judgment) ;;
            *)
              rebase_indexes="$rebase_indexes$index
"
              drop_lines="$drop_lines
REBASED $entry_path $latest_tag"
              ;;
          esac
        # REBASE-FILE-END
        fi
      fi
    done < <(jq -r '.decisions | to_entries[]
      | [.key, .value.path, (if .value | has("key") then 1 else 0 end), .value.decision, (.value.key // "")] | join("\t")' "$file")
    [ -n "$drop_indexes$rebase_indexes" ] || exit 0
    drop_json="$(printf '%s' "$drop_indexes" | jq -s -c '.')"
    rebase_json="$(printf '%s' "$rebase_indexes" | jq -s -c '.')"
    jq --argjson drop "$drop_json" --argjson rebase "$rebase_json" --arg tag "$latest_tag" '
      .decisions |= [to_entries[] | select(.key as $i | $drop | index($i) | not)
        | if (.key as $i | $rebase | index($i)) != null
          then .value |= (del(.reason) | .decision = "blend" | .tag = $tag | .baselineTag = $tag)
          else . end
        | .value]' "$file" \
      | write_atomically "$file" || { echo "could not write $file" >&2; exit 1; }
    printf '%s\n' "${drop_lines#?}"
    ;;

  context)
    [ -n "$target_path" ] || usage
    require_valid_file "$file"
    [ -f "$file" ] || exit 0
    jq -r --arg path "$target_path" --arg key "$key" --argjson has_key "$has_key" '
      .decisions[]
      | select(.path == $path and ((.key // null) == (if $has_key == 1 then $key else null end)))
      | select(.decision == "keep" or .decision == "blend")
      | "EARLIER \(.tag) \(.decision)"' "$file"
    ;;

  *) usage ;;
esac
