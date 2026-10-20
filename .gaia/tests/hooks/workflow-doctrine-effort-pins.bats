#!/usr/bin/env bats

# Effort-pin guards for the workflow doctrine: every agent definition and every
# dispatch block that pins a model or a general-purpose agent also pins its
# effort, no named-agent dispatch, fork, lens preamble, skill frontmatter or
# descriptive page does. Each guard runs once on the real tree (must pass) and
# once per red twin on a mutated scratch copy (must fail). The helpers live in
# helpers/doctrine-pin-checks.sh; the model pin guards stay in
# workflow-doctrine-sources.bats.

bats_require_minimum_version 1.5.0

PIPELINE_FILES=(
  .claude/skills/gaia/references/spec.md
  .claude/skills/gaia/references/spec/audit.md
  .claude/skills/gaia/references/spec/lens-dispatch.md
  .claude/skills/gaia/references/spec/self-review-dispatch.md
  .claude/skills/gaia/references/spec/clarify-loop.md
  .claude/skills/gaia/references/spec/clarify-prompts.md
  .claude/skills/gaia/references/spec/system-prompt.md
  .claude/skills/gaia/references/plan/decomposition-audit.md
)

# The /gaia-plan playbook. Its planner dispatches carry the session-effort mark
# and no pin, so it holds no pin to satisfy the pipeline check; its other
# general-purpose dispatch blocks are checked by the planner tests below.
PLANNER_FILE=.claude/skills/gaia/references/plan.md

REFERENCES=.claude/skills/gaia/references
AUDIT_PROCEDURE="wiki/concepts/Audit Round Procedure.md"

setup() {
  . "$BATS_TEST_DIRNAME/helpers/doctrine-pin-checks.sh"
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  WIKI="$REPO_ROOT/wiki/concepts/Workflow Doctrine.md"
  TEMPORARY_DIRECTORY="$BATS_TEST_TMPDIR"
  SCRATCH_ROOT="$TEMPORARY_DIRECTORY/root"
  mkdir -p "$SCRATCH_ROOT"
}

# copy_into_scratch <relative path>: copies a tracked file to the same relative
# path under the scratch root and prints the copy's path.
copy_into_scratch() {
  mkdir -p "$(dirname "$SCRATCH_ROOT/$1")"
  cp "$REPO_ROOT/$1" "$SCRATCH_ROOT/$1"
  printf '%s\n' "$SCRATCH_ROOT/$1"
}

# ------------------------------------------------------------- real tree

# bats test_tags=whole-tree
@test "agents: every definition pins exactly one valid effort, and each is medium" {
  agents_effort_ok "$REPO_ROOT/.claude/agents" || {
    echo "bad agents:$AGENT_EFFORT_BAD" >&2
    return 1
  }
  agents_effort_level_ok "$REPO_ROOT/.claude/agents" medium || {
    echo "not medium:$AGENT_EFFORT_BAD" >&2
    return 1
  }
}

# bats test_tags=whole-tree
@test "skills: no tracked skill frontmatter pins an effort" {
  local skill_paths=() skill_path
  while IFS= read -r skill_path; do
    [ -n "$skill_path" ] || continue
    skill_paths+=("$REPO_ROOT/$skill_path")
  done < <(git -C "$REPO_ROOT" ls-files -z -- '.claude/skills/*/SKILL.md' 'frontend/.claude/skills/*/SKILL.md' | tr '\0' '\n')
  [ "${#skill_paths[@]}" -gt 0 ]
  skills_frontmatter_no_effort_ok "${skill_paths[@]}" || {
    echo "skill pins effort:$SKILL_EFFORT_BAD" >&2
    return 1
  }
}

# bats test_tags=whole-tree
@test "dispatch files: every model-pinning block in a dispatch file also pins effort" {
  local dispatch_paths=() dispatch_path
  while IFS= read -r dispatch_path; do
    [ -n "$dispatch_path" ] || continue
    dispatch_paths+=("$REPO_ROOT/$dispatch_path")
  done < <(dispatch_files "$REPO_ROOT" "$WIKI")
  [ "${#dispatch_paths[@]}" -gt 0 ]
  blocks_anchored_pinned_ok "$MODEL_PIN_RE" "${dispatch_paths[@]}" || {
    echo "unpinned blocks:$UNPINNED_BLOCKS" >&2
    return 1
  }
}

@test "pipeline files: each is covered, pinned, and has every dispatch block pinned" {
  [ "${#PIPELINE_FILES[@]}" -gt 0 ]
  pipeline_files_ok "$REPO_ROOT" "$WIKI" "${PIPELINE_FILES[@]}" || {
    echo "pipeline:$PIPELINE_BAD" >&2
    return 1
  }
}

@test "planner: plan.md pins every general-purpose dispatch block but the marked planner blocks, which carry no pin" {
  blocks_anchored_pinned_ok "$GP_DISPATCH_RE" "$REPO_ROOT/$PLANNER_FILE" || {
    echo "planner file:$UNPINNED_BLOCKS" >&2
    return 1
  }
  grep -qiE -- "$SESSION_EFFORT_MARK_RE" "$REPO_ROOT/$PLANNER_FILE"
}

# bats test_tags=whole-tree
@test "planner: only plan.md carries the session-effort mark" {
  local marked
  marked="$(session_effort_mark_files "$REPO_ROOT")"
  [ "$marked" = "$PLANNER_FILE" ] || {
    echo "marked files: $marked" >&2
    return 1
  }
}

# bats test_tags=whole-tree
@test "named agents: no named-agent or fork dispatch block carries an effort pin" {
  local scan_paths=() scan_path
  while IFS= read -r scan_path; do
    [ -n "$scan_path" ] || continue
    scan_paths+=("$REPO_ROOT/$scan_path")
  done < <(scan_root_markdown_files "$REPO_ROOT")
  [ "${#scan_paths[@]}" -gt 0 ]
  named_dispatch_no_effort_ok "${scan_paths[@]}" || {
    echo "named dispatch pinned:$NAMED_PINNED_BLOCKS" >&2
    return 1
  }
}

@test "lens preamble: the shared preamble and caller slots name no effort" {
  lens_preamble_no_effort_ok "$REPO_ROOT/$REFERENCES/spec/lens-dispatch.md"
}

# bats test_tags=whole-tree
@test "descriptive pages: none restates an effort pin" {
  descriptive_pages_no_pin_ok "$WIKI" "$REPO_ROOT" || {
    echo "descriptive pages:$DESCRIPTIVE_PINNED" >&2
    return 1
  }
}

# ---------------------------------------------------- red twins: agents

# copy_agents: copies the real agents directory to the scratch root and prints
# the path of its first file.
copy_agents() {
  mkdir -p "$SCRATCH_ROOT/agents"
  cp "$REPO_ROOT"/.claude/agents/*.md "$SCRATCH_ROOT/agents/"
  agents_effort_ok "$SCRATCH_ROOT/agents" || return 1
  find "$SCRATCH_ROOT/agents" -name '*.md' | sort | head -n 1
}

# bats test_tags=whole-tree
@test "agents red twin: a deleted effort line fails" {
  local target
  target="$(copy_agents)"
  sed '/^effort:/d' "$target" >"$target.new"
  if cmp -s "$target" "$target.new"; then return 1; fi
  mv "$target.new" "$target"
  if agents_effort_ok "$SCRATCH_ROOT/agents"; then return 1; fi
}

# bats test_tags=whole-tree
@test "agents red twin: a new agent with a model and no effort fails" {
  copy_agents >/dev/null
  printf -- '---\nname: scratch-agent\nmodel: sonnet\n---\nBody.\n' >"$SCRATCH_ROOT/agents/scratch-agent.md"
  if agents_effort_ok "$SCRATCH_ROOT/agents"; then return 1; fi
}

# bats test_tags=whole-tree
@test "agents red twin: an invalid level fails" {
  local target
  target="$(copy_agents)"
  sed 's/^effort: .*/effort: extreme/' "$target" >"$target.new"
  if cmp -s "$target" "$target.new"; then return 1; fi
  mv "$target.new" "$target"
  if agents_effort_ok "$SCRATCH_ROOT/agents"; then return 1; fi
}

# bats test_tags=whole-tree
@test "agents red twin: a second effort line fails" {
  local target
  target="$(copy_agents)"
  awk '{ print } /^effort:/ && !done { print "effort: medium"; done = 1 }' "$target" >"$target.new"
  if cmp -s "$target" "$target.new"; then return 1; fi
  mv "$target.new" "$target"
  if agents_effort_ok "$SCRATCH_ROOT/agents"; then return 1; fi
}

# bats test_tags=whole-tree
@test "agents red twin: a valid level other than medium passes the shape check and fails the level check" {
  local target
  target="$(copy_agents)"
  sed 's/^effort: .*/effort: high/' "$target" >"$target.new"
  if cmp -s "$target" "$target.new"; then return 1; fi
  mv "$target.new" "$target"
  agents_effort_ok "$SCRATCH_ROOT/agents"
  if agents_effort_level_ok "$SCRATCH_ROOT/agents" medium; then return 1; fi
}

# ------------------------------------------- red twins: per-block pins

# unpinned_block_count: how many entries the last blocks_anchored_pinned_ok
# call recorded.
unpinned_block_count() {
  printf '%s\n' "$UNPINNED_BLOCKS" | tr ' ' '\n' | grep -c '[^[:space:]]'
}

@test "block red twin: dropping only the lint stage effort bullet fails and names one block" {
  local source_path="$REFERENCES/wiki.md" copy
  copy="$(copy_into_scratch "$source_path")"
  blocks_anchored_pinned_ok "$MODEL_PIN_RE" "$copy"
  awk '
    prev ~ /"haiku"/ && /^- `effort`: `"medium"`$/ && !done { done = 1; prev = $0; next }
    { print; prev = $0 }
  ' "$copy" >"$copy.new"
  if cmp -s "$copy" "$copy.new"; then return 1; fi
  mv "$copy.new" "$copy"
  if blocks_anchored_pinned_ok "$MODEL_PIN_RE" "$copy"; then return 1; fi
  [ "$(unpinned_block_count)" -eq 1 ]
}

@test "block red twin: dropping the transitive refresh pin in update-deps fails and names one block" {
  local copy
  copy="$(copy_into_scratch .claude/skills/update-deps/SKILL.md)"
  blocks_anchored_pinned_ok "$MODEL_PIN_RE" "$copy"
  # shellcheck disable=SC2016 # the backticks are literal markdown
  sed '/Otherwise spawn a \*\*Haiku agent\*\*/ s/, `effort: "medium"`//' "$copy" >"$copy.new"
  if cmp -s "$copy" "$copy.new"; then return 1; fi
  mv "$copy.new" "$copy"
  if blocks_anchored_pinned_ok "$MODEL_PIN_RE" "$copy"; then return 1; fi
  [ "$(unpinned_block_count)" -eq 1 ]
}

@test "pipeline red twin: dropping a lens dispatch pin in the spec audit fails the anchored check and the pipeline check" {
  local copy
  copy="$(copy_into_scratch "$REFERENCES/spec/audit.md")"
  blocks_anchored_pinned_ok "$GP_DISPATCH_RE" "$copy"
  # shellcheck disable=SC2016 # the backticks are literal markdown
  sed '/^Spawn \*\*one `general-purpose` Agent per selected lens/ s/`effort: "medium"`/the effort/g' "$copy" >"$copy.new"
  if cmp -s "$copy" "$copy.new"; then return 1; fi
  mv "$copy.new" "$copy"
  if blocks_anchored_pinned_ok "$GP_DISPATCH_RE" "$copy"; then return 1; fi
  if pipeline_files_ok "$SCRATCH_ROOT" "$WIKI" "$REFERENCES/spec/audit.md"; then return 1; fi
}

@test "pipeline red twin: a pipeline file with every effort pin removed fails" {
  local copy
  copy="$(copy_into_scratch "$REFERENCES/plan/decomposition-audit.md")"
  pipeline_files_ok "$SCRATCH_ROOT" "$WIKI" "$REFERENCES/plan/decomposition-audit.md"
  # shellcheck disable=SC2016 # the backticks are literal markdown
  sed -E 's/effort[`"]*:[[:space:]]*[`"\\]*(low|medium|high|xhigh|max)/removed/g' "$copy" >"$copy.new"
  if cmp -s "$copy" "$copy.new"; then return 1; fi
  mv "$copy.new" "$copy"
  if grep -qiE -- "$EFFORT_PIN_RE" "$copy"; then return 1; fi
  if pipeline_files_ok "$SCRATCH_ROOT" "$WIKI" "$REFERENCES/plan/decomposition-audit.md"; then return 1; fi
}

# -------------------------------------------------- red twins: the planner

# anchored_blocks_pinned_ok <file>: both anchored checks pass on the file.
anchored_blocks_pinned_ok() {
  blocks_anchored_pinned_ok "$GP_DISPATCH_RE" "$1" && blocks_anchored_pinned_ok "$MODEL_PIN_RE" "$1"
}

@test "planner red twin: each marked planner site that regains an effort pin fails" {
  local copy line_number seen=0
  copy="$(copy_into_scratch "$PLANNER_FILE")"
  anchored_blocks_pinned_ok "$copy"
  while IFS= read -r line_number; do
    [ -n "$line_number" ] || continue
    seen=$((seen + 1))
    # shellcheck disable=SC2016 # the backticks are literal markdown
    awk -v target="$line_number" 'NR == target { $0 = $0 " Pass `effort: \"medium\"`." } { print }' "$copy" >"$copy.new"
    if cmp -s "$copy" "$copy.new"; then return 1; fi
    if anchored_blocks_pinned_ok "$copy.new"; then
      echo "pin at line $line_number passed" >&2
      return 1
    fi
    case "$UNPINNED_BLOCKS" in *marked-pinned:*) ;; *) return 1 ;; esac
  done < <(grep -niE -- "$SESSION_EFFORT_MARK_RE" "$copy" | cut -d: -f1)
  [ "$seen" -gt 0 ]
}

@test "planner red twin: an unpinned general-purpose dispatch in plan.md fails, and so does a planner launch stripped of its mark" {
  local copy
  copy="$(copy_into_scratch "$PLANNER_FILE")"
  blocks_anchored_pinned_ok "$GP_DISPATCH_RE" "$copy"
  # shellcheck disable=SC2016 # the backticks are literal markdown
  printf '\nSpawn one `general-purpose` Agent per lens.\n' >"$copy.added"
  cat "$copy" "$copy.added" >"$copy.new"
  if blocks_anchored_pinned_ok "$GP_DISPATCH_RE" "$copy.new"; then return 1; fi
  sed 's/ (the planner runs at the session effort, per step 2)//' "$copy" >"$copy.unmarked"
  if cmp -s "$copy" "$copy.unmarked"; then return 1; fi
  if blocks_anchored_pinned_ok "$GP_DISPATCH_RE" "$copy.unmarked"; then return 1; fi
}

@test "planner red twin: the decomposition audit's lens dispatch block without its pins fails while the file keeps a pin" {
  local relative="$REFERENCES/plan/decomposition-audit.md" copy
  copy="$(copy_into_scratch "$relative")"
  pipeline_files_ok "$SCRATCH_ROOT" "$WIKI" "$relative"
  # shellcheck disable=SC2016 # the backticks are literal markdown
  sed -E '/^[34]\. / s/`effort: "medium"`/the effort/g' "$copy" >"$copy.new"
  if cmp -s "$copy" "$copy.new"; then return 1; fi
  mv "$copy.new" "$copy"
  grep -qiE -- "$EFFORT_PIN_RE" "$copy"
  if pipeline_files_ok "$SCRATCH_ROOT" "$WIKI" "$relative"; then return 1; fi
  case "$PIPELINE_BAD" in *gp-unpinned:*) ;; *) return 1 ;; esac
}

@test "planner red twin: the session-effort mark in a second file is reported" {
  local relative="$REFERENCES/spec/resume.md" scratch_repo="$TEMPORARY_DIRECTORY/repo"
  mkdir -p "$scratch_repo/$(dirname "$relative")" "$scratch_repo/$(dirname "$PLANNER_FILE")"
  cp "$REPO_ROOT/$PLANNER_FILE" "$scratch_repo/$PLANNER_FILE"
  cp "$REPO_ROOT/$relative" "$scratch_repo/$relative"
  printf '\nThe resumed author runs at the session effort.\n' >>"$scratch_repo/$relative"
  git -C "$scratch_repo" init -q
  git -C "$scratch_repo" add "$relative" "$PLANNER_FILE"
  [ "$(session_effort_mark_files "$scratch_repo" | grep -c .)" -eq 2 ]
}

# remove_pin_site_entry <relative path> <output page>: writes the doctrine page
# with that path's backticks dropped, so the token no longer reads as an entry.
remove_pin_site_entry() {
  awk -v token="\`$1\`" -v plain="$1" '
    { while ((at = index($0, token)) > 0) { $0 = substr($0, 1, at - 1) plain substr($0, at + length(token)) } print }
  ' "$WIKI" >"$2"
  if cmp -s "$WIKI" "$2"; then return 1; fi
  return 0
}

# bats test_tags=whole-tree
@test "coverage red twins: an uncovered pipeline file fails both the pipeline check and the coverage check" {
  local relative page
  for relative in "$REFERENCES/spec/audit.md" "$REFERENCES/plan/decomposition-audit.md"; do
    page="$TEMPORARY_DIRECTORY/page-$(basename "$relative")"
    remove_pin_site_entry "$relative" "$page"
    if pipeline_files_ok "$REPO_ROOT" "$page" "$relative"; then return 1; fi
    if pin_sites_covered_ok "$REPO_ROOT" "$page"; then return 1; fi
    case "$PIN_UNCOVERED" in *"$relative"*) ;; *) return 1 ;; esac
  done
}

@test "fixer block red twin: removing only the Agent block effort line fails, floor prose does not satisfy the pin" {
  local copy
  copy="$(copy_into_scratch "$AUDIT_PROCEDURE")"
  blocks_anchored_pinned_ok "$MODEL_PIN_RE" "$copy"
  awk '/^  effort: "medium",$/ && !done { done = 1; next } { print }' "$copy" >"$copy.new"
  if cmp -s "$copy" "$copy.new"; then return 1; fi
  mv "$copy.new" "$copy"
  grep -qiE 'effort' "$copy"
  if blocks_anchored_pinned_ok "$MODEL_PIN_RE" "$copy"; then return 1; fi
}

@test "coverage red twin: an unlisted file that pins an effort is reported uncovered" {
  local relative="$REFERENCES/spec/resume.md" scratch_repo="$TEMPORARY_DIRECTORY/repo"
  mkdir -p "$scratch_repo/$(dirname "$relative")"
  cp "$REPO_ROOT/$relative" "$scratch_repo/$relative"
  # shellcheck disable=SC2016 # the backticks are literal markdown
  printf '\nDispatch a fresh `general-purpose` agent with `effort: "medium"`.\n' >>"$scratch_repo/$relative"
  git -C "$scratch_repo" init -q
  git -C "$scratch_repo" config user.email test@example.com
  git -C "$scratch_repo" config user.name test
  git -C "$scratch_repo" config commit.gpgsign false
  git -C "$scratch_repo" add "$relative"
  if pin_sites_covered_ok "$scratch_repo" "$WIKI"; then return 1; fi
  case "$PIN_UNCOVERED" in *"$relative"*) ;; *) return 1 ;; esac
}

# ------------------------------------- red twins: where a pin must not be

@test "named agent red twins: an effort on a member block, a fork, or a real agent name fails; a general-purpose pin passes" {
  local copy
  copy="$(copy_into_scratch "$AUDIT_PROCEDURE")"
  named_dispatch_no_effort_ok "$copy"
  awk '{ print } /subagent_type: "<member-name>"/ && !done { print "    effort: \"medium\","; done = 1 }' "$copy" >"$copy.new"
  if cmp -s "$copy" "$copy.new"; then return 1; fi
  if named_dispatch_no_effort_ok "$copy.new"; then return 1; fi
  printf 'Agent(subagent_type: "fork", effort: "medium", prompt: "...")\n' >"$TEMPORARY_DIRECTORY/fork.md"
  if named_dispatch_no_effort_ok "$TEMPORARY_DIRECTORY/fork.md"; then return 1; fi
  printf 'Agent(subagent_type: "fitness-judge", effort: "medium", prompt: "...")\n' >"$TEMPORARY_DIRECTORY/judge.md"
  if named_dispatch_no_effort_ok "$TEMPORARY_DIRECTORY/judge.md"; then return 1; fi
  printf 'Agent(subagent_type: "general-purpose", effort: "medium", prompt: "...")\n' >"$TEMPORARY_DIRECTORY/general.md"
  named_dispatch_no_effort_ok "$TEMPORARY_DIRECTORY/general.md"
}

# bats test_tags=whole-tree
@test "skills red twin: an effort line in a skill frontmatter fails" {
  local source_path copy
  source_path="$(git -C "$REPO_ROOT" ls-files -z -- '.claude/skills/*/SKILL.md' | tr '\0' '\n' | head -n 1)"
  [ -n "$source_path" ]
  copy="$(copy_into_scratch "$source_path")"
  skills_frontmatter_no_effort_ok "$copy"
  awk 'NR == 1 { print; print "effort: medium"; next } { print }' "$copy" >"$copy.new"
  if cmp -s "$copy" "$copy.new"; then return 1; fi
  if skills_frontmatter_no_effort_ok "$copy.new"; then return 1; fi
}

@test "lens preamble red twin: an effort inside the shared preamble fails" {
  local copy
  copy="$(copy_into_scratch "$REFERENCES/spec/lens-dispatch.md")"
  lens_preamble_no_effort_ok "$copy"
  awk '{ print } /^## Shared preamble/ { print ""; print "Pass `effort: \"medium\"`." }' "$copy" >"$copy.new"
  if cmp -s "$copy" "$copy.new"; then return 1; fi
  if lens_preamble_no_effort_ok "$copy.new"; then return 1; fi
  sed 's/^## Write and return/## Write and hand back/' "$copy" >"$copy.renamed"
  if cmp -s "$copy" "$copy.renamed"; then return 1; fi
  if lens_preamble_no_effort_ok "$copy.renamed"; then return 1; fi
}

# bats test_tags=whole-tree
@test "descriptive page red twin: a restated effort pin on a descriptive page fails" {
  local entry
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    copy_into_scratch "$entry" >/dev/null
  done < <(pin_site_bullet_entries "$WIKI" '- Descriptive wiki pages')
  mkdir -p "$SCRATCH_ROOT/wiki/concepts"
  cp "$WIKI" "$SCRATCH_ROOT/wiki/concepts/Workflow Doctrine.md"
  descriptive_pages_no_pin_ok "$SCRATCH_ROOT/wiki/concepts/Workflow Doctrine.md" "$SCRATCH_ROOT"
  # shellcheck disable=SC2016 # the backticks are literal markdown
  printf '\nExecutors run on `effort: "medium"`.\n' >>"$SCRATCH_ROOT/wiki/concepts/GAIA Plan.md"
  if descriptive_pages_no_pin_ok "$SCRATCH_ROOT/wiki/concepts/Workflow Doctrine.md" "$SCRATCH_ROOT"; then return 1; fi
}

# ----------------------------------------------------------- the regexes

# matches_effort_pin <text>: rc 0 when EFFORT_PIN_RE matches the text.
matches_effort_pin() {
  printf '%s\n' "$1" | grep -qiE -- "$EFFORT_PIN_RE"
}

@test "effort pin regex: compact JSON, the parameter name, and the slash command are not pins; the four pin spellings are" {
  local sample
  # shellcheck disable=SC2016 # the backticks are literal markdown
  for sample in '"effort":"high"' 'the per-call `effort` parameter' 'consider `/effort high` before starting'; do
    if matches_effort_pin "$sample"; then return 1; fi
  done
  # shellcheck disable=SC2016 # the backticks are literal markdown
  for sample in 'effort: medium' '`effort: "medium"`' '- `effort`: `"medium"`' 'effort: \"medium\"'; do
    matches_effort_pin "$sample" || return 1
  done
  true
}
