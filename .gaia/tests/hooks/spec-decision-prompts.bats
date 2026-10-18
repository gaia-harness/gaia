#!/usr/bin/env bats

# Doc pins for the closed-set decision prompts of /gaia-spec and /gaia-plan:
# each converted site asks through AskUserQuestion and never says "plain
# prompt" again, and every review or audit finding prompt keeps its batching
# sentence. Each guard runs once on the real tree (must pass) and once on a
# mutated scratch copy (must fail).

bats_require_minimum_version 1.5.0

REFERENCES=.claude/skills/gaia/references
BATCHING_SENTENCE='up to 4 questions per `AskUserQuestion` call'

# One site per row: file|start ERE|end ERE|converted|batches. A site runs from
# its start line through the line before the next end match. A converted site
# asks through AskUserQuestion and never says "plain prompt"; a batching site
# carries the batching sentence. Hard constraint 3 batches but is not
# converted: it still sends open-ended clarify questions to a plain prompt.
SITES=(
  "$REFERENCES/spec.md|^### 4\. Gate 1|^### 5\.|yes|no"
  "$REFERENCES/spec.md|^### 8\. Gate 2|^### 9\.|yes|no"
  "$REFERENCES/spec.md|^3\. \*\*One question at a time|^4\. \*\*Two-gate|no|yes"
  "$REFERENCES/spec/self-review-dispatch.md|^## 6b\.|^## 6c\.|yes|yes"
  "$REFERENCES/spec/audit.md|^\*\*Interactive\.\*\*|^$|yes|yes"
  "$REFERENCES/plan/decomposition-audit.md|^\*\*Interactive:\*\*|^$|yes|yes"
  "$REFERENCES/spec/clarify-loop.md|^- \*\*Error|^- \*\*Contradictory|yes|no"
)

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  SCRATCH_ROOT="$BATS_TEST_TMPDIR/root"
  mkdir -p "$SCRATCH_ROOT"
}

# site_text <file> <start ERE> <end ERE>: prints the site's lines. The EREs
# travel through ENVIRON because awk -v expands backslash escapes, which would
# strip the \. and \* the patterns rely on.
site_text() {
  SITE_START="$2" SITE_END="$3" awk '
    inside && $0 ~ ENVIRON["SITE_END"] { exit }
    !inside && $0 ~ ENVIRON["SITE_START"] { inside = 1 }
    inside { print }
  ' "$1"
}

# sites_ok <root>: checks every site under <root>; prints each failure on
# stderr and returns 1 when any site fails.
sites_ok() {
  local root="$1" row file start end converted batching text failed=0 checked=0
  for row in "${SITES[@]}"; do
    IFS='|' read -r file start end converted batching <<<"$row"
    text="$(site_text "$root/$file" "$start" "$end")"
    if [ -z "$text" ]; then
      echo "site not found: $file /$start/" >&2
      failed=1
      continue
    fi
    checked=$((checked + 1))
    if [ "$converted" = yes ] && grep -qi -- 'plain prompt' <<<"$text"; then
      echo "says plain prompt: $file /$start/" >&2
      failed=1
    fi
    if [ "$converted" = yes ] && ! grep -qF -- 'AskUserQuestion' <<<"$text"; then
      echo "no AskUserQuestion: $file /$start/" >&2
      failed=1
    fi
    if [ "$batching" = yes ] && ! grep -qF -- "$BATCHING_SENTENCE" <<<"$text"; then
      echo "lost the batching sentence: $file /$start/" >&2
      failed=1
    fi
  done
  if [ "$checked" -ne "${#SITES[@]}" ]; then
    echo "checked $checked of ${#SITES[@]} sites" >&2
    failed=1
  fi
  return "$failed"
}

# copy_tree_into_scratch: copies every site file to the scratch root.
copy_tree_into_scratch() {
  local row file
  for row in "${SITES[@]}"; do
    file="${row%%|*}"
    mkdir -p "$(dirname "$SCRATCH_ROOT/$file")"
    cp "$REPO_ROOT/$file" "$SCRATCH_ROOT/$file"
  done
}

@test "real tree: every converted site asks through AskUserQuestion, and review prompts batch" {
  sites_ok "$REPO_ROOT"
}

@test "real tree: the open-ended prompts stay plain" {
  grep -qE -- 'What do you want to spec\?.*use a plain prompt' "$REPO_ROOT/$REFERENCES/spec.md"
  grep -qF -- 'ask: **"What do you want me to orchestrate?"** and wait' "$REPO_ROOT/$REFERENCES/plan.md"
}

@test "red twin: a gate that says plain prompt again fails" {
  copy_tree_into_scratch
  local file="$SCRATCH_ROOT/$REFERENCES/spec.md"
  awk '{ print } /^### 8\. Gate 2/ { print "Use a plain prompt, not `AskUserQuestion`." }' \
    "$file" >"$file.new"
  mv "$file.new" "$file"
  run sites_ok "$SCRATCH_ROOT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"says plain prompt"* ]]
}

@test "red twin: a finding prompt that loses its batching sentence fails" {
  copy_tree_into_scratch
  local file="$SCRATCH_ROOT/$REFERENCES/spec/audit.md"
  sed 's/up to 4 questions per `AskUserQuestion` call/one question per call/' "$file" >"$file.new"
  mv "$file.new" "$file"
  run sites_ok "$SCRATCH_ROOT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"lost the batching sentence"* ]]
}

@test "red twin: a site whose heading moved fails as not found" {
  copy_tree_into_scratch
  local file="$SCRATCH_ROOT/$REFERENCES/plan/decomposition-audit.md"
  sed 's/^\*\*Interactive:\*\*/**Interactive mode:**/' "$file" >"$file.new"
  mv "$file.new" "$file"
  run sites_ok "$SCRATCH_ROOT"
  [ "$status" -eq 1 ]
  [[ "$output" == *"site not found"* ]]
}
