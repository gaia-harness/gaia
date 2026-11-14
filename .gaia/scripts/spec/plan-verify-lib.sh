#!/usr/bin/env bash
# Sourced by plan-verify.sh: the README and ORCHESTRATOR.md readers and the
# test-table checks. Relies on the globals of the caller (plan_directory, readme,
# orchestrator, spec_path, repository_root, script_directory) and its fail().
# shellcheck disable=SC2154 # the globals are assigned by the sourcing script
# Prints `<phase><TAB><stem>` for each backticked task-<name> stem in the tasks
# cell of a README `| Phase <N> |` row.
readme_phase_stems() {
  awk -F'|' '
    { phase = $2; gsub(/^[ \t]+|[ \t]+$/, "", phase) }
    phase ~ /^Phase [0-9]+$/ {
      sub(/^Phase /, "", phase)
      cell = $3
      while (match(cell, /`task-[a-z0-9][a-z0-9-]*`/)) {
        print phase "\t" substr(cell, RSTART + 1, RLENGTH - 2)
        cell = substr(cell, RSTART + RLENGTH)
      }
    }' "$1"
}

# Prints the entry of ORCHESTRATOR.md for phase $2: ENTRY, then its lines.
phase_entry() {
  awk -v phase="$2" '
    { trimmed = $0; sub(/^[ \t]+/, "", trimmed); sub(/[ \t\r]+$/, "", trimmed) }
    trimmed ~ /^```/ { in_fence = !in_fence; if (inside) print; next }
    !in_fence && inside && (trimmed ~ /^\*\*Phase / || trimmed ~ /^## /) { exit }
    !in_fence && !inside && index(trimmed, "**Phase " phase ", ") == 1 { inside = 1; print "ENTRY"; print; next }
    inside { print }' "$1"
}
# The security writer owes a line in the entry of each phase that owns a security row.
security_writer_check() {
  local table="$plan_directory/tests.json" rows_text stems_text row_id row_task phase
  [ -f "$table" ] || return 0
  command -v node >/dev/null 2>&1 || return 0
  rows_text=$(node -e '
    let table;
    try { table = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")); } catch { process.exit(0); }
    for (const row of Array.isArray(table && table.rows) ? table.rows : []) {
      if (row && typeof row.security === "string" && row.security !== "none") console.log([row.id, row.task].join("\t"));
    }' "$table" 2>/dev/null) || return 0
  [ -n "$rows_text" ] || return 0
  [ -f "$readme" ] && [ -f "$orchestrator" ] || return 0
  stems_text=$(readme_phase_stems "$readme")
  while IFS=$'\t' read -r row_id row_task; do
    [ -n "$row_id" ] || continue
    phase=$(awk -F'\t' -v stem="$row_task" '$2 == stem { print $1; exit }' <<<"$stems_text")
    [ -n "$phase" ] || continue
    phase_entry "$orchestrator" "$phase" | grep -qE '^[[:space:]]*- Security writer:' \
      || fail "ORCHESTRATOR.md: Phase $phase owns security row $row_id but its entry has no '- Security writer:' line"
  done <<<"$rows_text"
}
# The table: keys from the SPEC (and its AUDIT.md), then test-table.mjs verify.
table_check() {
  local keys_file table_script="$repository_root/.gaia/scripts/test-design/test-table.mjs"
  local keys_script="$script_directory/requirement-keys.sh" audit_path='' relayed=0 verify_status=0 line_text
  local keys_errors verify_errors
  if ! command -v node >/dev/null 2>&1; then
    fail "test table not verified: node is not installed"
    return 0
  fi
  if [ ! -f "$table_script" ] || [ ! -f "$keys_script" ]; then
    fail "test table not verified: $table_script or $keys_script is missing"
    return 0
  fi
  keys_file=$(mktemp "${TMPDIR:-/tmp}/plan-verify-keys.XXXXXX") || { fail "test table not verified: cannot create a temporary keys file"; return 0; }
  keys_errors=$(mktemp "${TMPDIR:-/tmp}/plan-verify-keys-errors.XXXXXX") || { rm -f "$keys_file"; fail "test table not verified: cannot create a temporary file"; return 0; }
  if [ -n "$spec_path" ]; then
    audit_path="$(dirname "$spec_path")/AUDIT.md"
    if [ -f "$audit_path" ]; then
      bash "$keys_script" --spec "$spec_path" --audit "$audit_path" >"$keys_file" 2>"$keys_errors" || verify_status=$?
    else
      bash "$keys_script" --spec "$spec_path" >"$keys_file" 2>"$keys_errors" || verify_status=$?
    fi
  else
    bash "$keys_script" --description >"$keys_file" 2>"$keys_errors" || verify_status=$?
  fi
  if [ "$verify_status" -ne 0 ]; then
    fail "test table not verified: requirement-keys.sh exited $verify_status: $(head -n 1 "$keys_errors")"
    rm -f "$keys_file" "$keys_errors"
    return 0
  fi
  verify_status=0
  node "$table_script" verify --plan-dir "$plan_directory" --keys "$keys_file" >/dev/null 2>"$keys_errors" || verify_status=$?
  verify_errors=$(cat "$keys_errors")
  rm -f "$keys_file" "$keys_errors"
  case "$verify_status" in
    0) return 0 ;;
    1)
      while IFS= read -r line_text; do
        [ -n "$line_text" ] || continue
        fail "$line_text"
        relayed=1
      done <<<"$verify_errors"
      [ "$relayed" -eq 1 ] || fail "test-table.mjs verify exited 1 with no failure line"
      ;;
    *) fail "test table not verified: test-table.mjs verify exited $verify_status: $(head -n 1 <<<"$verify_errors")" ;;
  esac
}
