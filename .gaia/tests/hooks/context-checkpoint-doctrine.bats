#!/usr/bin/env bats

# Static guard for the context checkpoint doctrine: the file the checkpoint hook
# injects verbatim, plus the surfaces that point at it (the always-loaded rule
# and the Workflow Doctrine wiki page). Run it with
# `.gaia/scripts/bats5.sh .gaia/tests/hooks/context-checkpoint-doctrine.bats < /dev/null`.
#
# Each guard is a helper that takes the file to check, so the same helper runs
# once on the real tree (must pass) and once on a mutated scratch copy (must
# fail). Helpers return explicitly (never lean on `set -e`, which is suppressed
# inside `if`/`||`); tests call them in `if` form so a red twin that stops
# failing fails the test.

# bats file_tags=whole-tree

bats_require_minimum_version 1.5.0

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  DOCTRINE="$REPO_ROOT/.claude/doctrine/context-checkpoint.md"
  RULE="$REPO_ROOT/.claude/rules/context-discipline.md"
  WIKI="$REPO_ROOT/wiki/concepts/Workflow Doctrine.md"
  EXCLUDE="$REPO_ROOT/.gaia/release-exclude"
  WIKI_HEADING='## Context checkpoint'
  WIKI_PAGE_PATH='wiki/concepts/Workflow Doctrine.md'
  TEMPORARY_DIRECTORY="$BATS_TEST_TMPDIR"
}

# ---------------------------------------------------------------- helpers

# One row per required statement: kind (F fixed string, R extended regex), then
# the text. Keep each statement's literal on one line of the doctrine so a
# line-deletion twin can remove exactly it.
ANCHORS=(
  'F|look for a chance to clear'
  'F|clear unless the remaining work is small'
  'F|Fire and skull: clear now'
  'F|no background task, sub-agent or monitor'
  'F|nothing is half-applied'
  'F|The hook cannot detect this'
  'F|you judge it'
  'F|Save the place before you ask'
  'F|Then ask'
  'F|Commit and push first'
  'F|`RUNNING`'
  'F|`PROGRESS.md`'
  'F|committed phase boundary'
  'F|draft cache'
  'F|current-state file'
  'F|.gaia/local/runs/<branch>/STATE.md'
  'F|.gaia/local/runs/session-<session id>/STATE.md'
  'F|The `Save path:` line'
  'F|Never the scratchpad'
  'F|`Facts`'
  'F|`Status checklist`'
  'F|`NEXT:`'
  'F|4 KB'
  'F|rewritten in place'
  'F|interactive only'
  'F|`AskUserQuestion`'
  'F|exactly two options'
  'F|`Continue here` and `Clear and resume`'
  'F|(Recommended)'
  'F|one-line reason'
  'F|a few steps'
  'F|runs mostly in sub-agents'
  'F|riskier than finishing'
  'F|when unsure'
  'F|pre-merge audit'
  'F|Never skip the save and ask'
  'F|nearly-done session gets `Continue here`'
  'R|always recommend .Clear and resume., whatever the remaining work'
  'F|The reason states the band'
  'F|keep working until the next band'
  'F|run `/clear`'
  'F|info string `text`'
  'F|naming the state file path, the goal and the next step'
  'F|never points at this session'
  'F|no further tool calls'
  'F|With no human in the session, never ask'
  'F|At red and fire, save and continue'
  'F|At skull, save, print the continuation prompt in a `text` fence, report, and stop'
  'F|`/loop`'
  'F|Headless and scheduled'
  'F|never fire'
)

anchors_ok() {
  local file_path="$1" anchor kind pattern
  [ -f "$file_path" ] || return 1
  for anchor in "${ANCHORS[@]}"; do
    kind="${anchor%%|*}"
    pattern="${anchor#*|}"
    case "$kind" in
      F) grep -qF -- "$pattern" "$file_path" || return 1 ;;
      R) grep -qE -- "$pattern" "$file_path" || return 1 ;;
      *) return 1 ;;
    esac
  done
  return 0
}

# the file with every line matching one anchor removed
without_anchor_lines() {
  local anchor="$1" file_path="$2" kind pattern
  kind="${anchor%%|*}"
  pattern="${anchor#*|}"
  case "$kind" in
    F) grep -vF -- "$pattern" "$file_path" || true ;;
    R) grep -vE -- "$pattern" "$file_path" || true ;;
    *) return 1 ;;
  esac
  return 0
}

# the save step's first line precedes the first line naming AskUserQuestion
save_before_ask_ok() {
  local file_path="$1" save_line ask_line
  [ -f "$file_path" ] || return 1
  save_line="$(grep -nF -- 'Save the place' "$file_path" | head -n 1 | cut -d: -f1)"
  ask_line="$(grep -nF -- 'AskUserQuestion' "$file_path" | head -n 1 | cut -d: -f1)"
  [ -n "$save_line" ] || return 1
  [ -n "$ask_line" ] || return 1
  [ "$save_line" -lt "$ask_line" ] || return 1
  return 0
}

no_third_option_ok() {
  local file_path="$1"
  [ -f "$file_path" ] || return 1
  grep -qiE 'accept[ -]and[ -]stop' "$file_path" && return 1
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

# the band values live only in the lib, so the file spells no run of digits and no percent sign
no_band_numbers_ok() {
  local file_path="$1"
  [ -f "$file_path" ] || return 1
  grep -qE '[0-9]{2,}' "$file_path" && return 1
  grep -qF '%' "$file_path" && return 1
  return 0
}

no_ids_ok() {
  local file_path="$1"
  [ -f "$file_path" ] || return 1
  grep -qE 'SPEC-[0-9]|UAT-[0-9]|PLAN-[0-9]|#[0-9]' "$file_path" && return 1
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

# every line of the rule naming the checkpoint also names the wiki page that holds the reasoning
rule_pointer_ok() {
  local file_path="$1" checkpoint_lines
  [ -f "$file_path" ] || return 1
  checkpoint_lines="$(grep -F -- 'context checkpoint' "$file_path")"
  [ -n "$checkpoint_lines" ] || return 1
  printf '%s\n' "$checkpoint_lines" | grep -qvF -- "$WIKI_PAGE_PATH" && return 1
  return 0
}

# the heading that follows `## Resume`
wiki_heading_after_resume() {
  awk '/^## / { if (previous == "## Resume") { print $0; exit } previous = $0 }' "$1"
}

wiki_section_body() {
  awk -v heading="$WIKI_HEADING" '
    $0 == heading { on = 1; next }
    on && /^## / { exit }
    on { print }
  ' "$1"
}

wiki_section_ok() {
  local file_path="$1" body
  [ -f "$file_path" ] || return 1
  [ "$(wiki_heading_after_resume "$file_path")" = "$WIKI_HEADING" ] || return 1
  body="$(wiki_section_body "$file_path")"
  [ -n "$body" ] || return 1
  printf '%s\n' "$body" | grep -qF -- '.claude/doctrine/context-checkpoint.md' || return 1
  printf '%s\n' "$body" | grep -qF -- '(Recommended)' && return 1
  printf '%s\n' "$body" | grep -qF -- 'a few steps' && return 1
  printf '%s\n' "$body" | grep -qF -- 'pre-merge audit' && return 1
  printf '%s\n' "$body" | grep -q '[0-9]' && return 1
  return 0
}

# the wiki with one line planted directly under the section heading
plant_in_wiki_section() {
  awk -v heading="$WIKI_HEADING" -v planted="$2" '{ print } $0 == heading { print planted }' "$1"
}

# the wiki with the section moved to sit after Concurrency limits
move_wiki_section_down() {
  awk -v heading="$WIKI_HEADING" '
    FNR == NR {
      if ($0 == heading) inside = 1
      else if (inside && /^## /) inside = 0
      if (inside) section = section $0 "\n"
      next
    }
    {
      if ($0 == heading) skipping = 1
      else if (skipping && /^## /) skipping = 0
      if (skipping) next
      if ($0 == "## Initiative linking") printf "%s", section
      print
    }
  ' "$1" "$1"
}

# ------------------------------------------------------------- the doctrine

@test "doctrine: the file exists and is not empty" {
  [ -s "$DOCTRINE" ]
}

@test "doctrine anchors: every required statement is present" {
  [ "${#ANCHORS[@]}" -gt 0 ]
  anchors_ok "$DOCTRINE"
}

@test "doctrine anchors red twins: deleting any anchor's line fails the check" {
  local anchor index=0 visited=0 mutated
  for anchor in "${ANCHORS[@]}"; do
    index=$((index + 1))
    mutated="$TEMPORARY_DIRECTORY/without-anchor-$index.md"
    without_anchor_lines "$anchor" "$DOCTRINE" >"$mutated"
    if cmp -s "$DOCTRINE" "$mutated"; then return 1; fi
    if anchors_ok "$mutated"; then return 1; fi
    visited=$((visited + 1))
  done
  [ "$visited" -eq "${#ANCHORS[@]}" ]
}

@test "doctrine anchors red twin: an unknown anchor kind fails" {
  local original=("${ANCHORS[@]}")
  ANCHORS=('Z|anything')
  if anchors_ok "$DOCTRINE"; then ANCHORS=("${original[@]}"); return 1; fi
  ANCHORS=("${original[@]}")
  true
}

@test "doctrine: there are exactly two options and no third" {
  no_third_option_ok "$DOCTRINE"
}

@test "doctrine third-option red twin: a planted Accept and stop line fails" {
  { cat "$DOCTRINE"; printf -- '- `Accept and stop`: end the session.\n'; } >"$TEMPORARY_DIRECTORY/third-option.md"
  if no_third_option_ok "$TEMPORARY_DIRECTORY/third-option.md"; then return 1; fi
  { cat "$DOCTRINE"; printf -- '- accept-and-stop\n'; } >"$TEMPORARY_DIRECTORY/third-option-dashed.md"
  if no_third_option_ok "$TEMPORARY_DIRECTORY/third-option-dashed.md"; then return 1; fi
  true
}

@test "doctrine: the save step comes before the question" {
  save_before_ask_ok "$DOCTRINE"
}

@test "doctrine order red twin: the save step moved below the question fails" {
  {
    grep -vF -- 'Save the place' "$DOCTRINE" || true
    grep -F -- 'Save the place' "$DOCTRINE"
  } >"$TEMPORARY_DIRECTORY/swapped-order.md"
  if cmp -s "$DOCTRINE" "$TEMPORARY_DIRECTORY/swapped-order.md"; then return 1; fi
  if save_before_ask_ok "$TEMPORARY_DIRECTORY/swapped-order.md"; then return 1; fi
  true
}

# ------------------------------------------------------------------ budget

@test "doctrine budget: byte cap, one trailing newline, no control characters" {
  document_shape_ok "$DOCTRINE"
}

@test "doctrine budget red twins: oversize, trailing blank line, no final newline, control character" {
  local size padding
  size="$(wc -c <"$DOCTRINE" | tr -d ' ')"
  padding=$((3585 - size - 1))
  [ "$padding" -gt 0 ]
  { cat "$DOCTRINE"; head -c "$padding" /dev/zero | tr '\0' x; printf '\n'; } >"$TEMPORARY_DIRECTORY/oversize.md"
  [ "$(wc -c <"$TEMPORARY_DIRECTORY/oversize.md" | tr -d ' ')" -eq 3585 ]
  if document_shape_ok "$TEMPORARY_DIRECTORY/oversize.md"; then return 1; fi
  { cat "$DOCTRINE"; printf '\n'; } >"$TEMPORARY_DIRECTORY/blank-tail.md"
  if document_shape_ok "$TEMPORARY_DIRECTORY/blank-tail.md"; then return 1; fi
  head -c $((size - 1)) "$DOCTRINE" >"$TEMPORARY_DIRECTORY/no-newline.md"
  if document_shape_ok "$TEMPORARY_DIRECTORY/no-newline.md"; then return 1; fi
  { cat "$DOCTRINE"; printf 'bell\001\n'; } >"$TEMPORARY_DIRECTORY/control.md"
  if document_shape_ok "$TEMPORARY_DIRECTORY/control.md"; then return 1; fi
  true
}

# --------------------------------------------------- numbers and working ids

@test "doctrine: no band numbers and no percent sign" {
  no_band_numbers_ok "$DOCTRINE"
}

@test "doctrine band-number red twins: a planted number run or percent sign fails" {
  { cat "$DOCTRINE"; printf 'Red starts at 70 tokens.\n'; } >"$TEMPORARY_DIRECTORY/number.md"
  if no_band_numbers_ok "$TEMPORARY_DIRECTORY/number.md"; then return 1; fi
  { cat "$DOCTRINE"; printf 'A mark of 5%% here.\n'; } >"$TEMPORARY_DIRECTORY/percent.md"
  if no_band_numbers_ok "$TEMPORARY_DIRECTORY/percent.md"; then return 1; fi
  true
}

@test "doctrine: no working-document ids" {
  no_ids_ok "$DOCTRINE"
}

@test "doctrine id red twins: planted SPEC, UAT, plan and issue ids fail" {
  local planted index=0
  for planted in 'See SPEC-7.' 'See UAT-3.' 'See PLAN-2.' 'See #4.'; do
    index=$((index + 1))
    { cat "$DOCTRINE"; printf '%s\n' "$planted"; } >"$TEMPORARY_DIRECTORY/id-$index.md"
    if no_ids_ok "$TEMPORARY_DIRECTORY/id-$index.md"; then return 1; fi
  done
  [ "$index" -eq 4 ]
}

# ----------------------------------------------------------------- release

@test "release-exclude: the doctrine file and the hook ship" {
  local shipped_path checked_count=0
  for shipped_path in .claude/doctrine/context-checkpoint.md .claude/hooks/context-checkpoint-inject.sh; do
    checked_count=$((checked_count + 1))
    not_excluded_ok "$EXCLUDE" "$shipped_path"
  done
  [ "$checked_count" -eq 2 ]
}

@test "release-exclude red twins: the directory, or either exact path, is caught" {
  { cat "$EXCLUDE"; printf '.claude/doctrine\n'; } >"$TEMPORARY_DIRECTORY/exclude-directory"
  if not_excluded_ok "$TEMPORARY_DIRECTORY/exclude-directory" .claude/doctrine/context-checkpoint.md; then return 1; fi
  { cat "$EXCLUDE"; printf '.claude/hooks/context-checkpoint-inject.sh\n'; } >"$TEMPORARY_DIRECTORY/exclude-hook"
  if not_excluded_ok "$TEMPORARY_DIRECTORY/exclude-hook" .claude/hooks/context-checkpoint-inject.sh; then return 1; fi
  { cat "$EXCLUDE"; printf '# .claude/doctrine\n'; } >"$TEMPORARY_DIRECTORY/exclude-comment"
  not_excluded_ok "$TEMPORARY_DIRECTORY/exclude-comment" .claude/doctrine/context-checkpoint.md
}

# ------------------------------------------------------------ doc surfaces

@test "rule: the line naming the context checkpoint also names the wiki page" {
  rule_pointer_ok "$RULE"
}

@test "rule pointer red twins: the pointer line removed, or its page path removed, fails" {
  grep -vF -- 'context checkpoint' "$RULE" >"$TEMPORARY_DIRECTORY/rule-no-pointer.md" || true
  if cmp -s "$RULE" "$TEMPORARY_DIRECTORY/rule-no-pointer.md"; then return 1; fi
  if rule_pointer_ok "$TEMPORARY_DIRECTORY/rule-no-pointer.md"; then return 1; fi
  sed "s|$WIKI_PAGE_PATH|elsewhere.md|g" "$RULE" >"$TEMPORARY_DIRECTORY/rule-no-path.md"
  if cmp -s "$RULE" "$TEMPORARY_DIRECTORY/rule-no-path.md"; then return 1; fi
  if rule_pointer_ok "$TEMPORARY_DIRECTORY/rule-no-path.md"; then return 1; fi
  true
}

@test "wiki: the checkpoint section follows Resume, links the doctrine, restates nothing, spells no number" {
  wiki_section_ok "$WIKI"
}

@test "wiki section red twins: moved below Concurrency limits, link removed, rule restated, number planted" {
  move_wiki_section_down "$WIKI" >"$TEMPORARY_DIRECTORY/wiki-moved.md"
  if cmp -s "$WIKI" "$TEMPORARY_DIRECTORY/wiki-moved.md"; then return 1; fi
  grep -qxF -- "$WIKI_HEADING" "$TEMPORARY_DIRECTORY/wiki-moved.md" || return 1
  if wiki_section_ok "$TEMPORARY_DIRECTORY/wiki-moved.md"; then return 1; fi

  sed 's|\.claude/doctrine/context-checkpoint\.md|elsewhere.md|g' "$WIKI" >"$TEMPORARY_DIRECTORY/wiki-no-link.md"
  if cmp -s "$WIKI" "$TEMPORARY_DIRECTORY/wiki-no-link.md"; then return 1; fi
  if wiki_section_ok "$TEMPORARY_DIRECTORY/wiki-no-link.md"; then return 1; fi

  plant_in_wiki_section "$WIKI" 'Recommend `Continue here` (Recommended).' >"$TEMPORARY_DIRECTORY/wiki-restated.md"
  if cmp -s "$WIKI" "$TEMPORARY_DIRECTORY/wiki-restated.md"; then return 1; fi
  if wiki_section_ok "$TEMPORARY_DIRECTORY/wiki-restated.md"; then return 1; fi

  plant_in_wiki_section "$WIKI" 'It fires at 5 bands.' >"$TEMPORARY_DIRECTORY/wiki-number.md"
  if cmp -s "$WIKI" "$TEMPORARY_DIRECTORY/wiki-number.md"; then return 1; fi
  if wiki_section_ok "$TEMPORARY_DIRECTORY/wiki-number.md"; then return 1; fi
  true
}
