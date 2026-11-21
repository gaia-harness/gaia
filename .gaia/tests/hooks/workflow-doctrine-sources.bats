#!/usr/bin/env bats

# Static guard for the workflow doctrine sources: the always-loaded rule, the
# injected execution doctrine, the wiki page, the hook, and their registrations.
#
# Each guard is a helper that takes the file (or root) to check and runs on the
# real tree. Helpers return explicitly (never lean on `set -e`, which is
# suppressed inside `if`/`||`).

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

# ----------------------------------------------------------- 1. rule budget

@test "rule budget: the real rule is within 8 lines, 1200 bytes, no frontmatter" {
  rule_budget_ok "$RULE"
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

# -------------------------------------------------------- 7. model names

# ------------------------------------------------ 8. wiki headings and markers

# ------------------------------------------------------- 9. no working-doc ids

# ------------------------------------------ 10. presence and ledger internals

# --------------------------------------------------------- 11. registrations

@test "registrations: SessionStart covers all four sources; EnterWorktree and Bash groups include the hook" {
  settings_ok "$SETTINGS"
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

# ------------------------------------------------------------- 13. registry

@test "registry: runs/ (shared) and cache/doctrine-injected.* (main-only) entries carry their retention (runs is branch-spent, the marker ages out)" {
  registry_ok "$REGISTRY"
}

# --------------------------------------------------------------- 14. links

# ------------------------------------------------------------ 15. pin sites

# The helpers and the model pin regex live in helpers/doctrine-pin-checks.sh.

# bats test_tags=whole-tree
@test "pin sites: every model-pinning file has a doctrine entry and every doctrine entry names a tracked file" {
  local derived frontmatter_pins file_path
  derived="$(pin_site_files "$REPO_ROOT")"
  [ -n "$derived" ]
  # An independent source: every frontmatter pin must be in the derived set.
  frontmatter_pins="$(git -C "$REPO_ROOT" grep -l -E '^model:' -- .claude apps/web/.claude)"
  [ -n "$frontmatter_pins" ]
  while IFS= read -r file_path; do
    grep -qxF -- "$file_path" <<<"$derived" || return 1
  done <<<"$frontmatter_pins"
  pin_sites_covered_ok "$REPO_ROOT" "$WIKI" || {
    echo "uncovered:$PIN_UNCOVERED" >&2
    return 1
  }
  [ -n "$(pin_site_entries "$WIKI")" ]
  pin_site_entries_live_ok "$REPO_ROOT" "$WIKI"
}
