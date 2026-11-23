# shellcheck shell=bash
#
# The check and settled subcommands of audit-fix-verify.sh: input validation,
# the judgment of the fixer's delta, the audit-artifact scan, the error log
# every finding is written to, and the re-check that HEAD, the judged tree and
# the fixer's result file have not moved before the round stages them. Sourced
# only by audit-fix-verify.sh from its own directory, so a pinned copy sources
# the pinned library. That script's header
# owns the input and output shapes and the error kinds; FORBIDDEN_PATHS stays
# in that script too, and ENFORCEMENT_PATHS is in audit-fix-verify-state-lib.sh.
#
# Reads the caller's option globals, TEMPORARY_DIRECTORY and _here, and calls
# the helpers of audit-fix-verify-state-lib.sh.

# shellcheck disable=SC2154  # _here and the option globals are set by audit-fix-verify.sh, which sources this file

ERRORS_FILE=''
add_error() {
  local detail="$2"
  detail=${detail//$'\t'/ }
  detail=${detail//$'\n'/ }
  printf '%s\t%s\n' "$1" "$detail" >>"$ERRORS_FILE"
  printf '%s: %s\n' "$1" "$detail" >&2
}

has_errors() { [ -s "$ERRORS_FILE" ]; }

# Prints a declared-paths file's non-blank lines. A file written without a
# trailing newline (the Write tool's) still ends its last path, so two files
# read in turn never fuse into one path.
read_declared_paths() {
  local declared_line
  while IFS= read -r declared_line || [ -n "$declared_line" ]; do
    [ -z "$declared_line" ] || printf '%s\n' "$declared_line"
  done <"$1"
  return 0
}

# Reads paths on stdin and reports each one that is empty, absolute, starts
# with a dash, or carries a `..` segment.
validate_paths() {
  local label="$1" file_path
  while IFS= read -r file_path; do
    case "$file_path" in
      '' | /* | -*)
        add_error bad-input "path in $label is empty, absolute or starts with a dash: $file_path"
        continue
        ;;
    esac
    case "/$file_path/" in
      */../*) add_error bad-input "path in $label has a .. segment: $file_path" ;;
    esac
  done
}

finish_check() {
  jq -Rn --argjson round "$ROUND" --argjson attempt "$ATTEMPT" --slurpfile judged "$TEMPORARY_DIRECTORY/judged.json" \
    '[inputs | split("\t") | {kind: .[0], detail: (.[1:] | join("\t"))}] as $errors
     | {schema: 1, round: $round, attempt: $attempt, pass: ($errors | length == 0), errors: $errors,
        judged: (if ($errors | length == 0) then $judged[0] else null end)}' \
    <"$ERRORS_FILE" | _atomic_write "$OUTPUT_FILE" || {
    printf 'audit-fix-verify: cannot write %s\n' "$OUTPUT_FILE" >&2
    exit 1
  }
  if has_errors; then exit 1; fi
  exit 0
}

command_check() {
  local file_path input_label dispositions_ok=1 result_ok=1 baseline_ok=1 input_spec extra_declared_file protected_path main_checkout_root sha result_sha
  if [ -z "$ROOT" ] || [ -z "$OUTPUT_FILE" ] || [ -z "$DISPOSITIONS_FILE" ] || [ -z "$DISPOSITIONS_SHA" ] || [ -z "$BASELINE_FILE" ] ||
    [ -z "$BASELINE_SHA" ] || [ -z "$RESULT" ] || ! _is_uint "$ROUND" || ! _is_uint "$ATTEMPT"; then
    die_usage 'check is missing a required option (or --round/--attempt is not an integer)'
  fi
  TEMPORARY_DIRECTORY="$(mktemp -d)" || exit 1
  ERRORS_FILE="$TEMPORARY_DIRECTORY/errs"
  : >"$ERRORS_FILE"
  printf 'null\n' >"$TEMPORARY_DIRECTORY/judged.json"

  # Input validation. Anything wrong here ends the check before the delta is
  # computed: a file the fixer could have altered is never analysed.
  for input_spec in "$DISPOSITIONS_FILE:dispositions:$DISPOSITIONS_SHA" "$BASELINE_FILE:baseline:$BASELINE_SHA"; do
    sha="${input_spec##*:}"
    input_spec="${input_spec%:*}"
    input_label="${input_spec##*:}"
    input_spec="${input_spec%:*}"
    if [ ! -r "$input_spec" ]; then
      add_error bad-input "$input_label file unreadable: $input_spec"
    elif [ "$(_sha256 <"$input_spec")" != "$sha" ]; then
      add_error bad-input "$input_label file digest differs from the recorded digest: $input_spec"
      [ "$input_label" = dispositions ] && dispositions_ok=0 || baseline_ok=0
    fi
  done
  if [ ! -r "$RESULT" ]; then
    add_error bad-input "result file unreadable: $RESULT"
    result_ok=0
  fi
  [ -r "$DISPOSITIONS_FILE" ] || dispositions_ok=0
  [ -r "$BASELINE_FILE" ] || baseline_ok=0

  if [ "$dispositions_ok" = 1 ]; then
    if ! jq -e 'type == "object"' "$DISPOSITIONS_FILE" >/dev/null 2>&1; then
      add_error bad-input "dispositions file does not parse as a JSON object: $DISPOSITIONS_FILE"
      dispositions_ok=0
    elif ! jq -e --argjson round "$ROUND" '.round == $round' "$DISPOSITIONS_FILE" >/dev/null 2>&1; then
      add_error bad-input "dispositions file carries the wrong round (want $ROUND)"
      dispositions_ok=0
    elif ! jq -e '(.entries | type == "array") and all(.entries[]; type == "object" and (.path | type == "string"))
        and ((.enforcement_paths_allowed // []) | type == "array")
        and all((.enforcement_paths_allowed // [])[]; type == "string")' "$DISPOSITIONS_FILE" >/dev/null 2>&1; then
      add_error bad-input "dispositions file has the wrong shape: $DISPOSITIONS_FILE"
      dispositions_ok=0
    fi
  fi
  if [ "$result_ok" = 1 ]; then
    if ! jq -e 'type == "object"' "$RESULT" >/dev/null 2>&1; then
      add_error bad-input "result file does not parse as a JSON object: $RESULT"
      result_ok=0
    elif ! jq -e --argjson round "$ROUND" '.round == $round' "$RESULT" >/dev/null 2>&1; then
      add_error bad-input "result file carries the wrong round (want $ROUND)"
      result_ok=0
    elif ! jq -e --argjson attempt "$ATTEMPT" '.attempt == $attempt' "$RESULT" >/dev/null 2>&1; then
      add_error bad-input "result attempt differs from --attempt $ATTEMPT"
      result_ok=0
    elif ! jq -e '(.results | type == "array")
        and all(.results[]; type == "object" and ((.changed_paths // []) | type == "array")
          and all((.changed_paths // [])[]; type == "string"))
        and ((.changed_paths // []) | type == "array") and all((.changed_paths // [])[]; type == "string")
        and ((.reverted_paths // []) | type == "array") and all((.reverted_paths // [])[]; type == "string")' \
      "$RESULT" >/dev/null 2>&1; then
      add_error bad-input "result file has the wrong shape: $RESULT"
      result_ok=0
    fi
  fi
  if [ "$baseline_ok" = 1 ]; then
    if ! jq -e 'type == "object"' "$BASELINE_FILE" >/dev/null 2>&1; then
      add_error bad-input "baseline file does not parse as a JSON object: $BASELINE_FILE"
      baseline_ok=0
    elif ! jq -e --argjson round "$ROUND" '.round == $round' "$BASELINE_FILE" >/dev/null 2>&1; then
      add_error bad-input "baseline file carries the wrong round (want $ROUND)"
      baseline_ok=0
    elif ! jq -e '(.head | type == "string") and (.index_digest | type == "string")
        and (.dirty | type == "object") and (.untracked | type == "array")
        and all(.untracked[]; type == "string")' "$BASELINE_FILE" >/dev/null 2>&1; then
      add_error bad-input "baseline file has the wrong shape: $BASELINE_FILE"
      baseline_ok=0
    elif ! _verify_pin "$BASELINE_FILE"; then
      add_error bad-input "the verifier files beside this script differ from the digest pinned in the baseline (or it records none): $BASELINE_FILE"
      baseline_ok=0
    fi
  fi

  if [ "$dispositions_ok" = 1 ]; then
    jq -r '.entries[].path, (.enforcement_paths_allowed // [])[]' "$DISPOSITIONS_FILE" | validate_paths dispositions
    jq -r '(.enforcement_paths_allowed // [])[]' "$DISPOSITIONS_FILE" >"$TEMPORARY_DIRECTORY/allowed"
    while IFS= read -r file_path; do
      jq -e --arg file_path "$file_path" '[.entries[] | select(.disposition == "fix" and .path == $file_path)] | length > 0' "$DISPOSITIONS_FILE" >/dev/null 2>&1 ||
        add_error bad-input "enforcement_paths_allowed names a path no fix entry names: $file_path"
    done <"$TEMPORARY_DIRECTORY/allowed"
  fi
  if [ "$result_ok" = 1 ]; then
    jq -r '(.changed_paths // [])[], (.results[] | (.changed_paths // [])[]), (.reverted_paths // [])[], (.results[].path | select(type == "string"))' \
      "$RESULT" | validate_paths result
  fi
  if [ "$baseline_ok" = 1 ]; then
    jq -r '(.dirty | keys[]), .untracked[]' "$BASELINE_FILE" | validate_paths baseline
  fi
  : >"$TEMPORARY_DIRECTORY/extra"
  while IFS= read -r extra_declared_file; do
    [ -n "$extra_declared_file" ] || continue
    if [ ! -r "$extra_declared_file" ]; then
      add_error bad-input "extra-declared file unreadable: $extra_declared_file"
      continue
    fi
    read_declared_paths "$extra_declared_file" | validate_paths extra-declared
    read_declared_paths "$extra_declared_file" >>"$TEMPORARY_DIRECTORY/extra"
  done <<EOF
$EXTRA_DECLARED_FILES
EOF

  if has_errors; then finish_check; fi

  if ! snapshot_state "$TEMPORARY_DIRECTORY/cur"; then
    add_error bad-input "cannot read repo state in $ROOT (or a path contains a newline)"
    finish_check
  fi
  compute_delta "$BASELINE_FILE" "$TEMPORARY_DIRECTORY/cur" || {
    add_error bad-input "cannot compute the delta from $BASELINE_FILE"
    finish_check
  }
  # The record settled compares against: this snapshot's paths and the result
  # file as read now. A record that cannot be made fails the check, so a pass
  # always carries one.
  result_sha="$(_sha256 <"$RESULT")" || result_sha=''
  if [ -z "$result_sha" ] || ! judged_paths "$TEMPORARY_DIRECTORY/cur" ||
    ! jq --arg result_sha "$result_sha" '{paths: ., result_sha: $result_sha}' \
      "$TEMPORARY_DIRECTORY/cur/judged.json" >"$TEMPORARY_DIRECTORY/judged.json"; then
    printf 'null\n' >"$TEMPORARY_DIRECTORY/judged.json"
    add_error bad-input "cannot record the judged tree in $ROOT"
  fi

  [ "$(cat "$TEMPORARY_DIRECTORY/cur/head")" = "$(jq -r '.head' "$BASELINE_FILE")" ] ||
    add_error head-moved "HEAD is $(cat "$TEMPORARY_DIRECTORY/cur/head"), baseline recorded $(jq -r '.head' "$BASELINE_FILE")"
  [ "$(cat "$TEMPORARY_DIRECTORY/cur/index_digest")" = "$(jq -r '.index_digest' "$BASELINE_FILE")" ] ||
    add_error index-changed 'the index differs from the baseline index digest'

  while IFS= read -r file_path; do
    [ -n "$file_path" ] && add_error missing-disposition "$file_path"
  done < <(jq -r --slurpfile result "$RESULT" '
    ($result[0].results) as $results
    | .entries[] | select(.disposition == "fix") as $fix_entry
    | select([$results[] | select(.member == $fix_entry.member and .finding_class == $fix_entry.finding_class
        and .path == $fix_entry.path and .line == $fix_entry.line
        and (.disposition == "fixed" or .disposition == "disputed" or .disposition == "cannot_fix"))] | length == 0)
    | "\($fix_entry.member) \($fix_entry.finding_class) \($fix_entry.path) \($fix_entry.line)"' "$DISPOSITIONS_FILE")

  jq -r '(.changed_paths // [])[], (.results[] | (.changed_paths // [])[])' "$RESULT" |
    cat - "$TEMPORARY_DIRECTORY/extra" | LC_ALL=C sort -u >"$TEMPORARY_DIRECTORY/declared"
  jq -r '(.reverted_paths // [])[]' "$RESULT" | LC_ALL=C sort -u >"$TEMPORARY_DIRECTORY/reverted"

  cat "$TEMPORARY_DIRECTORY/cur/d_mod" "$TEMPORARY_DIRECTORY/cur/d_unt" | LC_ALL=C sort -u >"$TEMPORARY_DIRECTORY/d_au"
  LC_ALL=C comm -23 "$TEMPORARY_DIRECTORY/d_au" "$TEMPORARY_DIRECTORY/declared" >"$TEMPORARY_DIRECTORY/undeclared"
  while IFS= read -r file_path; do
    [ -n "$file_path" ] && add_error undeclared-path "$file_path"
  done <"$TEMPORARY_DIRECTORY/undeclared"
  LC_ALL=C comm -23 "$TEMPORARY_DIRECTORY/cur/d_rev" "$TEMPORARY_DIRECTORY/reverted" >"$TEMPORARY_DIRECTORY/unrev"
  while IFS= read -r file_path; do
    [ -n "$file_path" ] && add_error undeclared-revert "$file_path"
  done <"$TEMPORARY_DIRECTORY/unrev"

  cat "$TEMPORARY_DIRECTORY/cur/d_mod" "$TEMPORARY_DIRECTORY/cur/d_rev" "$TEMPORARY_DIRECTORY/cur/d_unt" | LC_ALL=C sort -u >"$TEMPORARY_DIRECTORY/d_all"
  while IFS= read -r file_path; do
    [ -n "$file_path" ] || continue
    for protected_path in "${FORBIDDEN_PATHS[@]}"; do
      [ "$file_path" = "$protected_path" ] && add_error forbidden-path "$file_path"
    done
    for protected_path in "${ENFORCEMENT_PATHS[@]}"; do
      if [ "$file_path" = "$protected_path" ] && ! grep -Fxq -- "$file_path" "$TEMPORARY_DIRECTORY/allowed" 2>/dev/null; then
        add_error enforcement-path "$file_path"
      fi
    done
  done <"$TEMPORARY_DIRECTORY/d_all"

  # shellcheck source=main-root-lib.sh
  . "$_here/main-root-lib.sh"
  if main_checkout_root="$(gaia_resolve_main_root "$ROOT" 2>/dev/null)" && [ -n "$main_checkout_root" ]; then
    if [ -d "$main_checkout_root/.gaia/local/audit" ]; then
      # The audit directory is shared by every linked worktree, so a file
      # newer than the baseline is skipped only when it provably belongs to
      # another branch. A sidecar, ledger or scope file is skipped when its
      # name lacks this branch's slug. A marker or refusal (named by digest
      # only) is skipped when its body carries a well-formed tree that is
      # neither this root's HEAD tree nor its working-content tree, a sha other
      # than HEAD, and its name's digest is none of this branch's branch-own
      # digests: the merge gate reads a marker by that name and never reads
      # the body's tree, so a body that merely differs from HEAD proves
      # nothing. Anything that cannot be proven foreign counts, so the check
      # never narrows silently.
      slug=''
      # shellcheck source=audit-key-lib.sh
      . "$_here/audit-key-lib.sh"
      slug="$(gaia_branch_slug "$ROOT" 2>/dev/null)" || slug=''
      head_tree="$(git -C "$ROOT" rev-parse 'HEAD^{tree}' 2>/dev/null)" || head_tree=''
      head_sha="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null)" || head_sha=''
      worktree_tree="$(_working_tree_id)" || worktree_tree=''
      : >"$TEMPORARY_DIRECTORY/member-digests"
      digests_ok=0
      if [ -n "$worktree_tree" ] && [ -f "$ROOT/.claude/hooks/lib/audit-digest.sh" ]; then
        digests_ok=1
        for tree_reference in HEAD "$worktree_tree"; do
          # The batch form prints `<member><TAB><digest>` lines and nothing at
          # all when it cannot resolve the roster or the base. The merge base
          # comes from HEAD in both calls: a bare tree id has no history.
          # shellcheck source=/dev/null
          if ! member_digest_lines="$( (. "$ROOT/.claude/hooks/lib/audit-digest.sh" && audit_branch_digests_local "$ROOT" "$tree_reference") 2>/dev/null)" ||
            [ -z "$member_digest_lines" ]; then
            digests_ok=0
            break
          fi
          printf '%s\n' "$member_digest_lines" | cut -f2 >>"$TEMPORARY_DIRECTORY/member-digests"
        done
      fi
      find "$main_checkout_root/.gaia/local/audit" -type f -newer "$BASELINE_FILE" >"$TEMPORARY_DIRECTORY/audit-new" 2>/dev/null
      while IFS= read -r file_path; do
        [ -n "$file_path" ] || continue
        case "$file_path" in
          *.ok | *.refused)
            key="${file_path##*/}"
            key="${key%%.*}"
            if [ "$digests_ok" = 1 ] && [ -n "$head_tree" ] && [ -n "$worktree_tree" ] &&
              ! grep -Fxq -- "$key" "$TEMPORARY_DIRECTORY/member-digests" &&
              jq -e --arg head_tree "$head_tree" --arg worktree_tree "$worktree_tree" --arg head_sha "$head_sha" \
                '(type == "object") and ((.tree | type) == "string")
                  and (.tree | test("^[0-9a-f]{40}([0-9a-f]{24})?$"))
                  and (.tree != $head_tree) and (.tree != $worktree_tree) and ((.sha // "") != $head_sha)' "$file_path" >/dev/null 2>&1; then
              continue
            fi
            ;;
          *)
            if [ -n "$slug" ]; then
              case "${file_path##*/}" in
                *".$slug."*) ;;
                *) continue ;;
              esac
            fi
            ;;
        esac
        add_error audit-artifact-written "$file_path"
      done <"$TEMPORARY_DIRECTORY/audit-new"
    fi
  else
    add_error bad-input "cannot resolve the main checkout root from $ROOT"
  fi

  finish_check
}

# settled: the round runs it after a passing check and before it stages
# anything. A fixer can keep running after it returns (a background run that
# finishes later) and edit the tree or rewrite its result file; staging reads
# both, so either change would reach the round's commit unverified. Only the
# security writer's tests (--security-paths, written after the check) and, on
# the post-gate re-check alone, that attempt's autofix paths (--gate-paths) may
# differ; nothing else may. A gate path is never exempt before the gate, because
# the check already judged that content. --verifier-sha pins the verifier output
# so a fixer that can write the run folder cannot rewrite the judged record.
command_settled() {
  local exit_status=0 file_path paths_file judged_sha current_sha
  [ -z "$EXTRA_DECLARED_FILES" ] || die_usage 'settled takes --security-paths and --gate-paths, not --extra-declared'
  if [ -z "$ROOT" ] || [ -z "$BASELINE_FILE" ] || [ -z "$VERIFIER_FILE" ] || [ -z "$VERIFIER_SHA" ] ||
    [ -z "$RESULT" ] || [ -z "$SECURITY_PATHS_FILE" ]; then
    die_usage 'settled needs --root, --baseline, --verifier, --verifier-sha, --result and --security-paths'
  fi
  TEMPORARY_DIRECTORY="$(mktemp -d)" || exit 1
  _verify_pin "$BASELINE_FILE" || {
    printf 'bad-input: the verifier files beside this script differ from the digest pinned in %s\n' "$BASELINE_FILE" >&2
    exit 1
  }
  if [ ! -r "$VERIFIER_FILE" ] || [ "$(_sha256 <"$VERIFIER_FILE" 2>/dev/null)" != "$VERIFIER_SHA" ]; then
    printf 'bad-input: %s is unreadable or differs from the recorded verifier digest\n' "$VERIFIER_FILE" >&2
    exit 1
  fi
  jq -e '.pass == true and (.judged.paths | type == "object")
    and (.judged.result_sha | type == "string" and length > 0)' "$VERIFIER_FILE" >/dev/null 2>&1 || {
    printf 'bad-input: %s is not a passing verifier output with a judged record\n' "$VERIFIER_FILE" >&2
    exit 1
  }
  : >"$TEMPORARY_DIRECTORY/extra"
  for paths_file in "$SECURITY_PATHS_FILE" "$GATE_PATHS_FILE"; do
    [ -n "$paths_file" ] || continue
    [ -r "$paths_file" ] || {
      printf 'bad-input: declared-paths file unreadable: %s\n' "$paths_file" >&2
      exit 1
    }
    read_declared_paths "$paths_file" >>"$TEMPORARY_DIRECTORY/extra" || exit 1
  done
  LC_ALL=C sort -u "$TEMPORARY_DIRECTORY/extra" -o "$TEMPORARY_DIRECTORY/extra"
  if ! snapshot_state "$TEMPORARY_DIRECTORY/cur" || ! judged_paths "$TEMPORARY_DIRECTORY/cur"; then
    printf 'bad-input: cannot read repo state in %s\n' "$ROOT" >&2
    exit 1
  fi
  if [ "$(cat "$TEMPORARY_DIRECTORY/cur/head")" != "$(jq -r '.head' "$BASELINE_FILE" 2>/dev/null)" ]; then
    printf 'head-moved\n' >&2
    exit_status=1
  fi
  judged_sha="$(jq -r '.judged.result_sha' "$VERIFIER_FILE")"
  current_sha="$(_sha256 <"$RESULT" 2>/dev/null)" || current_sha=''
  if [ "$current_sha" != "$judged_sha" ]; then
    printf 'result-moved: %s\n' "$RESULT" >&2
    exit_status=1
  fi
  # Not piped into sort: a pipe would report sort's status, and a jq failure
  # would read as an unmoved tree.
  jq -r --slurpfile now "$TEMPORARY_DIRECTORY/cur/judged.json" \
    '.judged.paths as $judged_before | ($judged_before + $now[0]) | keys[] as $judged_path
      | select($judged_before[$judged_path] != $now[0][$judged_path]) | $judged_path' \
    "$VERIFIER_FILE" >"$TEMPORARY_DIRECTORY/moved.raw" || {
    printf 'bad-input: cannot compare the tree with %s\n' "$VERIFIER_FILE" >&2
    exit 1
  }
  LC_ALL=C sort -u "$TEMPORARY_DIRECTORY/moved.raw" >"$TEMPORARY_DIRECTORY/moved" || exit 1
  while IFS= read -r file_path; do
    [ -n "$file_path" ] || continue
    printf 'tree-moved: %s\n' "$file_path" >&2
    exit_status=1
  done < <(LC_ALL=C comm -23 "$TEMPORARY_DIRECTORY/moved" "$TEMPORARY_DIRECTORY/extra")
  exit "$exit_status"
}
