#!/usr/bin/env bash
# shellcheck shell=bash
#
# The audit-unit budget an unattended run spends in place of a human grant at
# an audit checkpoint. audit-loop-bound.sh is its only writer; audit-loop-eval.sh
# record-values reads it for the PR body's `budget grants:` count. Which
# checkpoints the budget may answer is the bound hook's decision (its header,
# THE AUTONOMY BUDGET); this file only counts.
#
# The budget's size is two fields of the autonomy switch, read through
# autonomy_field: audit_extra_units_per_pr and audit_units_pool. The spend
# lives in one record per switch content,
#   <main>/.gaia/local/protected/audit-budget/<switch blob hash>.json
#   {schema: 1, pool_spent: <n>, spent: {"<spend key>": <n>}}
# so a human rewrite of the switch starts a fresh budget, and Claude, denied
# every write to the protected folder (block-audit-loop-write.sh), can neither
# raise the budget nor reset the spend. The pool is one per record, shared by
# every branch; the spend key is `pr:<n>`, or `branch:<key>` while the branch
# has no pull request (gaia_audit_budget_keys). Units spent under branch:<key>
# before the pull request linked still count toward its per-PR limit.
#
# Source after audit-loop-state-lib.sh (gaia_loop_lock); gaia_audit_budget_spend also needs autonomy-lib.sh loaded.
#
# gaia_audit_budget_keys <loop state json> <branch key>
#   Prints the keys one branch's spend lives under, from the loop state alone:
#   the spend key first (`pr:<state .pr>` when linked, else `branch:<key>`),
#   then `branch:<key>` when the spend key is a pull request. The one source of
#   the key set for the spend and for record-values' `budget grants:` count.
# gaia_audit_budget_spend <main root> <spend key> [<also counted key>...]
#   Spends one unit under the record's lock, charged to the spend key; the
#   per-PR limit is checked against the units spent under the spend key and
#   every also counted key together. rc 0 prints `spent <units those keys have
#   spent> <pool left>`; rc 1 prints `refused <reason>`, reason one of
#   autonomy-off, no-budget (the switch sets no per-PR limit or no pool),
#   per-pr-limit, pool-empty; rc 5 prints why the record could
#   not be read or written. Only rc 0 spends.
# gaia_audit_budget_count <main root> <spend key>...
#   Prints the units spent under those keys summed over every record, 0 when
#   there are none. An unreadable record counts nothing.

_GAIA_AUDIT_BUDGET_RECORD_OK='type == "object" and .schema == 1
  and (.pool_spent | type == "number" and . == floor and . >= 0)
  and (.spent | type == "object" and all(.[]; type == "number" and . == floor and . >= 0))'

_gaia_audit_budget_directory() {
  printf '%s/.gaia/local/protected/audit-budget\n' "$1"
}

# _gaia_audit_budget_switch_hash <main root>: the switch's git blob hash.
_gaia_audit_budget_switch_hash() {
  local switch hash
  switch=$(autonomy_file "$1") || return 1
  hash=$(git hash-object --no-filters -- "$switch" 2>/dev/null) || return 1
  [[ $hash =~ ^[0-9a-f]{40}([0-9a-f]{24})?$ ]] || return 1
  printf '%s\n' "$hash"
}

gaia_audit_budget_keys() {
  local state_json="${1-}" branch_key="${2-}" pr_number
  pr_number=$(jq -r '(.pr // 0) | if type == "number" and . > 0 then . else empty end' <<<"$state_json" 2>/dev/null) || pr_number=''
  if [ -n "$pr_number" ]; then
    printf 'pr:%s\nbranch:%s\n' "$pr_number" "$branch_key"
  else
    printf 'branch:%s\n' "$branch_key"
  fi
}

gaia_audit_budget_spend() {
  local main="${1-}" key="${2-}" per_pr pool hash directory record_file record key_spent pool_spent temporary_file counted_keys
  shift 2 2>/dev/null || shift $#
  counted_keys=$(printf '%s\n' "$key" "$@" | jq -R . | jq -sc .)
  if ! per_pr=$(autonomy_field audit_extra_units_per_pr "$main") ||
    ! pool=$(autonomy_field audit_units_pool "$main") ||
    ! hash=$(_gaia_audit_budget_switch_hash "$main"); then
    printf 'refused autonomy-off\n'
    return 1
  fi
  # The fields and the hash must come from one switch content: a rewrite in
  # between would charge the new budget's size to the old record.
  [ "$(_gaia_audit_budget_switch_hash "$main")" = "$hash" ] || {
    printf 'the autonomy file changed while the budget was read\n'
    return 5
  }
  if [ "$per_pr" -le 0 ] || [ "$pool" -le 0 ]; then
    printf 'refused no-budget\n'
    return 1
  fi
  directory=$(_gaia_audit_budget_directory "$main")
  record_file="$directory/$hash.json"
  # A symlink would put the record where the protected-folder guard never looks.
  [ ! -L "$directory" ] && [ ! -L "$record_file" ] || {
    printf 'the budget record or its folder is a symlink\n'
    return 5
  }
  gaia_loop_lock "$record_file" "$(($(date +%s) + 5))" || {
    printf 'could not take the budget record lock %s.lock\n' "$record_file"
    return 5
  }
  if [ -e "$record_file" ]; then
    record=$(jq -c -s "if length == 1 and (.[0] | $_GAIA_AUDIT_BUDGET_RECORD_OK) then .[0] else error(\"corrupt\") end" "$record_file" 2>/dev/null) || {
      gaia_loop_unlock "$record_file"
      printf 'the budget record %s is unreadable\n' "$record_file"
      return 5
    }
  else
    record='{"schema":1,"pool_spent":0,"spent":{}}'
  fi
  key_spent=$(jq -r --argjson keys "$counted_keys" '[$keys[] as $counted | .spent[$counted] // 0] | add' <<<"$record")
  pool_spent=$(jq -r '.pool_spent' <<<"$record")
  if [ "$key_spent" -ge "$per_pr" ]; then
    gaia_loop_unlock "$record_file"
    printf 'refused per-pr-limit\n'
    return 1
  fi
  if [ "$pool_spent" -ge "$pool" ]; then
    gaia_loop_unlock "$record_file"
    printf 'refused pool-empty\n'
    return 1
  fi
  temporary_file="$record_file.tmp.$$.$RANDOM"
  if ! jq -c --arg key "$key" '.pool_spent += 1 | .spent[$key] = ((.spent[$key] // 0) + 1)' <<<"$record" >"$temporary_file" 2>/dev/null ||
    ! mv -f "$temporary_file" "$record_file"; then
    rm -f "$temporary_file"
    gaia_loop_unlock "$record_file"
    printf 'could not write the budget record %s\n' "$record_file"
    return 5
  fi
  gaia_loop_unlock "$record_file"
  printf 'spent %s %s\n' "$((key_spent + 1))" "$((pool - pool_spent - 1))"
}

gaia_audit_budget_count() {
  local main="${1-}" directory keys
  shift
  directory=$(_gaia_audit_budget_directory "$main")
  [ -d "$directory" ] && [ ! -L "$directory" ] || {
    printf '0\n'
    return 0
  }
  keys=$(printf '%s\n' "$@" | jq -R . | jq -sc .)
  find "$directory" -maxdepth 1 -type f -name '*.json' -print 2>/dev/null |
    while IFS= read -r record_file; do
      jq -s --argjson keys "$keys" "if length == 1 and (.[0] | $_GAIA_AUDIT_BUDGET_RECORD_OK) then .[0] as \$record | [\$keys[] | \$record.spent[.] // 0] | add // 0 else 0 end" "$record_file" 2>/dev/null || printf '0\n'
    done | awk '{ total += $1 } END { print total + 0 }'
}
