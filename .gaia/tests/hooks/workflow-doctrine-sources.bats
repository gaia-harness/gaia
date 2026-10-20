#!/usr/bin/env bats

# Static guard for the workflow doctrine sources: the always-loaded rule, the
# injected execution doctrine, the wiki page, the hook, and their registrations.
#
# Each guard is a helper that takes the file (or root) to check, so the same
# helper runs once on the real tree (must pass) and once on a mutated scratch
# copy (must fail). Helpers return explicitly (never lean on `set -e`, which is
# suppressed inside `if`/`||`); tests call them in `if` form so a red twin that
# stops failing fails the test.

bats_require_minimum_version 1.5.0

setup() {
  . "$BATS_TEST_DIRNAME/helpers/doctrine-pin-checks.sh"
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  RULE="$REPO_ROOT/.claude/rules/context-discipline.md"
  DOCTRINE_PATH="$REPO_ROOT/.claude/doctrine/execution.md"
  WIKI="$REPO_ROOT/wiki/concepts/Workflow Doctrine.md"
  SETTINGS="$REPO_ROOT/.claude/settings.json"
  REGISTRY="$REPO_ROOT/.gaia/state-registry.json"
  EXCLUDE="$REPO_ROOT/.gaia/release-exclude"
  TEMPORARY_DIRECTORY="$BATS_TEST_TMPDIR"
}

# ---------------------------------------------------------------- helpers

rule_budget_ok() {
  local file_path="$1" nonblank_line_count
  [ -f "$file_path" ] || return 1
  [ "$(head -n 1 "$file_path")" = "---" ] && return 1
  grep -q '^paths:' "$file_path" && return 1
  nonblank_line_count="$(grep -c '[^[:space:]]' "$file_path")"
  [ "$nonblank_line_count" -le 8 ] || return 1
  [ "$(wc -c <"$file_path" | tr -d ' ')" -le 1200 ] || return 1
  return 0
}

document_shape_ok() {
  local file_path="$1"
  [ -f "$file_path" ] || return 1
  [ "$(wc -c <"$file_path" | tr -d ' ')" -le 3584 ] || return 1
  [ "$(tail -c 1 "$file_path" | od -An -tx1 | tr -d ' \n')" = "0a" ] || return 1
  [ "$(tail -c 2 "$file_path" | od -An -tx1 | tr -d ' \n')" = "0a0a" ] && return 1
  LC_ALL=C grep -q $'[\x01-\x09\x0b-\x1f\x7f]' "$file_path" && return 1
  return 0
}

document_placement_ok() {
  local root="$1"
  [ -f "$root/.claude/doctrine/execution.md" ] || return 1
  [ -z "$(find "$root/.claude/rules" -name 'execution.md' 2>/dev/null)" ] || return 1
  return 0
}

# key line the hook emits for a branch name, then the payload size with a doctrine file
payload_ok() {
  local file_path="$1" name keyline total
  name="feat/$(head -c 123 /dev/zero | tr '\0' a)"
  [ "${#name}" = 128 ] || return 1
  keyline="Branch key: branch:$name. Link its initiative once with: bash .gaia/scripts/usage.sh link branch:$name research:<date>-<topic> (or issue:<n>)"
  total=$(($(printf '%s\n' "$keyline" | wc -c) + $(wc -c <"$file_path")))
  [ "$total" -le 4096 ] || return 1
  return 0
}

ANCHORS=(
  'I|never run git'
  'F|stage, commit, push, branch'
  'I|copy it in with one plain command'
  'F|audit-loop-unit'
  'I|sanctioned depth-2 orchestrator'
  'I|state-changing git and the Quality Gate'
)

anchors_ok() {
  local file_path="$1" anchor kind pattern
  [ -f "$file_path" ] || return 1
  for anchor in "${ANCHORS[@]}"; do
    kind="${anchor%%|*}"
    pattern="${anchor#*|}"
    case "$kind" in
      F) grep -qF -- "$pattern" "$file_path" || return 1 ;;
      I) grep -qiF -- "$pattern" "$file_path" || return 1 ;;
      R) grep -qiE -- "$pattern" "$file_path" || return 1 ;;
      *) return 1 ;;
    esac
  done
  return 0
}

settings_ok() {
  local file_path="$1"
  [ -f "$file_path" ] || return 1
  jq -e '[.hooks.SessionStart[]
      | select(((.matcher // "") as $m
          | ($m == "" or ((["startup","resume","clear","compact"] - ($m | split("|"))) | length == 0)))
        and any(.hooks[]; .command | contains("workflow-doctrine-inject.sh")))] | length == 1' "$file_path" >/dev/null || return 1
  jq -e '[.hooks.SessionStart[] | select(any(.hooks[]; .command | contains("workflow-doctrine-inject.sh")))] | length == 1' "$file_path" >/dev/null || return 1
  jq -e '[.hooks.PostToolUse[] | select(.matcher == "EnterWorktree" and any(.hooks[]; .command | contains("workflow-doctrine-inject.sh")))] | length == 1' "$file_path" >/dev/null || return 1
  jq -e '[.hooks.PostToolUse[] | select(.matcher == "Bash" and any(.hooks[]; .command | contains("workflow-doctrine-inject.sh")))] | length == 1' "$file_path" >/dev/null || return 1
  return 0
}

not_excluded_ok() {
  local exclude="$1" path="$2" line
  [ -f "$exclude" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in '' | '#'*) continue ;; esac
    line="${line%/}"
    [ -n "$line" ] || continue
    case "$path" in
      "$line" | "$line"/*) return 1 ;;
    esac
  done <"$exclude"
  return 0
}

registry_ok() {
  local file_path="$1"
  [ -f "$file_path" ] || return 1
  jq -e '[.entries[] | select(.path == "runs/" and .scope == "shared"
      and (.keyed_by | type == "string" and length > 0)
      and .retention.class == "branch-spent" and .retention.key == "normalized-path"
      and .retention.days == 7 and .retention.session_days == 30)] | length == 1' "$file_path" >/dev/null || return 1
  jq -e '[.entries[] | select(.path == "cache/doctrine-injected.*" and .scope == "main-only"
      and .keyed_by == null
      and .retention.class == "age" and .retention.days == 7)] | length == 1' "$file_path" >/dev/null || return 1
  return 0
}

pad_to() { # pad_to <src> <dst> <total bytes>: src plus filler so dst ends in one newline at <total> bytes
  local base
  base="$(wc -c <"$1" | tr -d ' ')"
  { cat "$1"; head -c $(($3 - base - 1)) /dev/zero | tr '\0' x; printf '\n'; } >"$2"
}

# ----------------------------------------------------------- 1. rule budget

@test "rule budget: the real rule is within 8 lines, 1200 bytes, no frontmatter" {
  rule_budget_ok "$RULE"
}

@test "rule budget red twins: frontmatter, 1201 bytes, and 9 lines each fail" {
  printf -- '---\npaths:\n  - "x"\n---\n' | cat - "$RULE" >"$TEMPORARY_DIRECTORY/fm.md"
  if rule_budget_ok "$TEMPORARY_DIRECTORY/fm.md"; then return 1; fi
  printf 'paths: x\n' | cat - "$RULE" >"$TEMPORARY_DIRECTORY/paths.md"
  if rule_budget_ok "$TEMPORARY_DIRECTORY/paths.md"; then return 1; fi
  pad_to "$RULE" "$TEMPORARY_DIRECTORY/big.md" 1201
  [ "$(wc -c <"$TEMPORARY_DIRECTORY/big.md" | tr -d ' ')" -eq 1201 ]
  if rule_budget_ok "$TEMPORARY_DIRECTORY/big.md"; then return 1; fi
  cp "$RULE" "$TEMPORARY_DIRECTORY/nine.md"
  while [ "$(grep -c '[^[:space:]]' "$TEMPORARY_DIRECTORY/nine.md")" -lt 9 ]; do printf '%s\n' '- x' >>"$TEMPORARY_DIRECTORY/nine.md"; done
  [ "$(grep -c '[^[:space:]]' "$TEMPORARY_DIRECTORY/nine.md")" -eq 9 ]
  if rule_budget_ok "$TEMPORARY_DIRECTORY/nine.md"; then return 1; fi
}

# ------------------------------------------------------------ 2. ban list

# ------------------------------------------------------- 3. rule directives

# ------------------------------------------------- 4. execution.md budget

@test "execution.md: size, single trailing newline, no control characters" {
  document_shape_ok "$DOCTRINE_PATH"
}

# bats test_tags=whole-tree
@test "execution.md placement: lives under .claude/doctrine, not under .claude/rules" {
  document_placement_ok "$REPO_ROOT"
  mkdir -p "$TEMPORARY_DIRECTORY/bad/.claude/rules" "$TEMPORARY_DIRECTORY/bad/.claude/doctrine"
  cp "$DOCTRINE_PATH" "$TEMPORARY_DIRECTORY/bad/.claude/doctrine/execution.md"
  cp "$DOCTRINE_PATH" "$TEMPORARY_DIRECTORY/bad/.claude/rules/execution.md"
  if document_placement_ok "$TEMPORARY_DIRECTORY/bad"; then return 1; fi
  mkdir -p "$TEMPORARY_DIRECTORY/moved/.claude/rules"
  cp "$DOCTRINE_PATH" "$TEMPORARY_DIRECTORY/moved/.claude/rules/execution.md"
  if document_placement_ok "$TEMPORARY_DIRECTORY/moved"; then return 1; fi
}

@test "execution.md red twins: 3585 bytes, trailing blank line, and a control character each fail" {
  pad_to "$DOCTRINE_PATH" "$TEMPORARY_DIRECTORY/over.md" 3585
  [ "$(wc -c <"$TEMPORARY_DIRECTORY/over.md" | tr -d ' ')" -eq 3585 ]
  if document_shape_ok "$TEMPORARY_DIRECTORY/over.md"; then return 1; fi
  { cat "$DOCTRINE_PATH"; printf '\n'; } >"$TEMPORARY_DIRECTORY/blank.md"
  if document_shape_ok "$TEMPORARY_DIRECTORY/blank.md"; then return 1; fi
  { cat "$DOCTRINE_PATH"; printf 'tab\there\n'; } >"$TEMPORARY_DIRECTORY/tab.md"
  if document_shape_ok "$TEMPORARY_DIRECTORY/tab.md"; then return 1; fi
}

# -------------------------------------------------------- 5. payload cap

@test "payload cap red twin: an oversize doctrine copy fails the same check" {
  pad_to "$DOCTRINE_PATH" "$TEMPORARY_DIRECTORY/big.md" 3800
  [ "$(wc -c <"$TEMPORARY_DIRECTORY/big.md" | tr -d ' ')" -eq 3800 ]
  if payload_ok "$TEMPORARY_DIRECTORY/big.md"; then return 1; fi
}

# ----------------------------------------------------------- 6. anchors

@test "execution.md anchors: every load-bearing instruction literal is present" {
  [ "${#ANCHORS[@]}" -gt 0 ]
  anchors_ok "$DOCTRINE_PATH"
}

@test "execution.md anchors red twin: the copy-in clause fails" {
  sed 's/copy it in with one plain command//g' "$DOCTRINE_PATH" >"$TEMPORARY_DIRECTORY/noewr.md"
  if cmp -s "$DOCTRINE_PATH" "$TEMPORARY_DIRECTORY/noewr.md"; then return 1; fi
  if anchors_ok "$TEMPORARY_DIRECTORY/noewr.md"; then return 1; fi
}

@test "execution.md exception red twin: dropping the audit-loop-unit sentence fails the anchors, and the real file names it" {
  grep -qF 'audit-loop-unit' "$DOCTRINE_PATH"
  grep -vF 'audit-loop-unit' "$DOCTRINE_PATH" >"$TEMPORARY_DIRECTORY/noexc.md"
  [ "$(wc -c <"$TEMPORARY_DIRECTORY/noexc.md" | tr -d ' ')" -lt "$(wc -c <"$DOCTRINE_PATH" | tr -d ' ')" ]
  if anchors_ok "$TEMPORARY_DIRECTORY/noexc.md"; then return 1; fi
  sed 's/sanctioned depth-2 orchestrator/orchestrator/' "$DOCTRINE_PATH" >"$TEMPORARY_DIRECTORY/nosanction.md"
  if cmp -s "$DOCTRINE_PATH" "$TEMPORARY_DIRECTORY/nosanction.md"; then return 1; fi
  if anchors_ok "$TEMPORARY_DIRECTORY/nosanction.md"; then return 1; fi
}

# -------------------------------------------------------- 7. model names

# ------------------------------------------------ 8. wiki headings and markers

# ------------------------------------------------------- 9. no working-doc ids

# ------------------------------------------ 10. presence and ledger internals

# --------------------------------------------------------- 11. registrations

@test "registrations: SessionStart covers all four sources; EnterWorktree and Bash groups include the hook" {
  settings_ok "$SETTINGS"
}

@test "registrations red twins: a three-source matcher and a Bash-group removal each fail" {
  jq '(.hooks.SessionStart[] | select(.matcher == "startup|resume|clear|compact") | .matcher) = "startup|resume|clear"' "$SETTINGS" >"$TEMPORARY_DIRECTORY/settings-matcher.json"
  if cmp -s "$SETTINGS" "$TEMPORARY_DIRECTORY/settings-matcher.json"; then return 1; fi
  if settings_ok "$TEMPORARY_DIRECTORY/settings-matcher.json"; then return 1; fi
  jq '.hooks.PostToolUse |= map(if .matcher == "Bash" then .hooks |= map(select(.command | contains("workflow-doctrine-inject.sh") | not)) else . end)' "$SETTINGS" >"$TEMPORARY_DIRECTORY/settings-bash.json"
  if cmp -s "$SETTINGS" "$TEMPORARY_DIRECTORY/settings-bash.json"; then return 1; fi
  if settings_ok "$TEMPORARY_DIRECTORY/settings-bash.json"; then return 1; fi
  jq '.hooks.PostToolUse |= map(if .matcher == "EnterWorktree" then .hooks |= map(select(.command | contains("workflow-doctrine-inject.sh") | not)) else . end)' "$SETTINGS" >"$TEMPORARY_DIRECTORY/settings-ew.json"
  if settings_ok "$TEMPORARY_DIRECTORY/settings-ew.json"; then return 1; fi
}

# ----------------------------------------------------- 12. release exclusion

@test "release-exclude: none of the four source paths is excluded" {
  local source_path checked_count=0
  for source_path in .claude/rules/context-discipline.md .claude/doctrine/execution.md \
    .claude/hooks/workflow-doctrine-inject.sh "wiki/concepts/Workflow Doctrine.md"; do
    checked_count=$((checked_count + 1))
    not_excluded_ok "$EXCLUDE" "$source_path"
  done
  [ "$checked_count" -eq 4 ]
}

@test "release-exclude red twin: a .claude/doctrine entry, or the exact path, is caught" {
  { cat "$EXCLUDE"; printf '.claude/doctrine\n'; } >"$TEMPORARY_DIRECTORY/exclude-dir"
  if not_excluded_ok "$TEMPORARY_DIRECTORY/exclude-dir" .claude/doctrine/execution.md; then return 1; fi
  { cat "$EXCLUDE"; printf 'wiki/concepts/Workflow Doctrine.md\n'; } >"$TEMPORARY_DIRECTORY/exclude-exact"
  if not_excluded_ok "$TEMPORARY_DIRECTORY/exclude-exact" "wiki/concepts/Workflow Doctrine.md"; then return 1; fi
  { cat "$EXCLUDE"; printf '# .claude/doctrine\n'; } >"$TEMPORARY_DIRECTORY/exclude-comment"
  not_excluded_ok "$TEMPORARY_DIRECTORY/exclude-comment" .claude/doctrine/execution.md
}

# ------------------------------------------------------------- 13. registry

@test "registry: runs/ (shared) and cache/doctrine-injected.* (main-only) entries carry their retention (runs is branch-spent, the marker ages out)" {
  registry_ok "$REGISTRY"
}

@test "registry red twins: dropping either entry fails" {
  jq '.entries |= map(select(.path != "runs/"))' "$REGISTRY" >"$TEMPORARY_DIRECTORY/reg-runs.json"
  if registry_ok "$TEMPORARY_DIRECTORY/reg-runs.json"; then return 1; fi
  jq '.entries |= map(select(.path != "cache/doctrine-injected.*"))' "$REGISTRY" >"$TEMPORARY_DIRECTORY/reg-marker.json"
  if registry_ok "$TEMPORARY_DIRECTORY/reg-marker.json"; then return 1; fi
  jq '.entries |= map(if .path == "runs/" then del(.retention) else . end)' "$REGISTRY" >"$TEMPORARY_DIRECTORY/reg-reaped.json"
  if registry_ok "$TEMPORARY_DIRECTORY/reg-reaped.json"; then return 1; fi
}

# --------------------------------------------------------------- 14. links

# ------------------------------------------------------------ 15. pin sites

# The helpers and the model and effort regexes live in
# helpers/doctrine-pin-checks.sh; the per-dispatch effort guards and their red
# twins live in workflow-doctrine-effort-pins.bats.

# bats test_tags=whole-tree
@test "pin sites: every file that pins a model matches an entry on the doctrine page" {
  local derived frontmatter_pins file_path
  derived="$(pin_site_files "$REPO_ROOT")"
  [ -n "$derived" ]
  # An independent source: every frontmatter pin must be in the derived set.
  frontmatter_pins="$(git -C "$REPO_ROOT" grep -l -E '^model:' -- .claude frontend/.claude)"
  [ -n "$frontmatter_pins" ]
  while IFS= read -r file_path; do
    grep -qxF -- "$file_path" <<<"$derived" || return 1
  done <<<"$frontmatter_pins"
  # A second independent source: every agent frontmatter effort line too.
  frontmatter_pins="$(git -C "$REPO_ROOT" grep -l -E '^effort:' -- .claude/agents)"
  [ -n "$frontmatter_pins" ]
  while IFS= read -r file_path; do
    grep -qxF -- "$file_path" <<<"$derived" || return 1
  done <<<"$frontmatter_pins"
  pin_sites_covered_ok "$REPO_ROOT" "$WIKI" || {
    echo "uncovered:$PIN_UNCOVERED" >&2
    return 1
  }
}

# bats test_tags=whole-tree
@test "pin sites: every entry on the doctrine page names a tracked file" {
  [ -n "$(pin_site_entries "$WIKI")" ]
  pin_site_entries_live_ok "$REPO_ROOT" "$WIKI"
}

# bats test_tags=whole-tree
@test "pin sites red twins: a dropped entry and a stale entry each fail" {
  # shellcheck disable=SC2016 # the backticks are literal markdown
  sed 's|`wiki/concepts/Audit Round Procedure\.md`|the round procedure page|' "$WIKI" >"$TEMPORARY_DIRECTORY/wiki-nopin.md"
  if cmp -s "$WIKI" "$TEMPORARY_DIRECTORY/wiki-nopin.md"; then return 1; fi
  if pin_sites_covered_ok "$REPO_ROOT" "$TEMPORARY_DIRECTORY/wiki-nopin.md"; then return 1; fi
  awk '{ print } $0 == "### Pin sites" { print ""; print "- Gone: `.claude/skills/does-not-exist/SKILL.md`." }' "$WIKI" >"$TEMPORARY_DIRECTORY/wiki-stale.md"
  if pin_site_entries_live_ok "$REPO_ROOT" "$TEMPORARY_DIRECTORY/wiki-stale.md"; then return 1; fi
  true
}
