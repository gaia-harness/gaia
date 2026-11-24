#!/usr/bin/env bats
# Doc-conformance for the research dispatch that writes the code map: the 5e
# dispatch prompt, its classify-and-fold handling, and the `## The code map`
# section that owns the entry shape. These are instruction-prose pins plus one
# executable check: the validation program is extracted from the section and
# run against fixtures, so a reflowed program that stops refusing a malformed
# entry goes red.
#
# Assertion style: .claude/rules/bats-assertions.md.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  CLARIFY_LOOP="$ROOT/.claude/skills/gaia/references/spec/clarify-loop.md"
  SPEC_PLAYBOOK="$ROOT/.claude/skills/gaia/references/spec.md"
  ROSTER_SUITE="$ROOT/.gaia/tests/lib/doc-noop-terminal-contract.bats"
}

# section_of <file> <heading line>
# Prints the section from its heading through the line before the next `## `.
section_of() {
  awk -v heading="$2" '
    $0 == heading { inside = 1; print; next }
    inside && /^## / { exit }
    inside { print }
  ' "$1"
}

# bullet_of <file> <section heading> <bullet prefix>
# Prints one bullet line of a section.
bullet_of() {
  section_of "$1" "$2" | grep -F -- "$3"
}

# validation_program
# Prints the jq program of the code map section's validation block.
validation_program() {
  section_of "$CLARIFY_LOOP" '## The code map' | awk '
    /^jq -e '"'"'$/ { inside = 1; next }
    inside && /^'"'"' <research file>$/ { exit }
    inside { print }
  '
}

# require_text <label> <text>
# Fails the test, naming the missing piece, when the text is empty.
require_text() {
  [ -n "$2" ] || { echo "missing: $1" >&2; return 1; }
}

@test "the research prompt names a pre-cleared JSON-array output file, the one-line reply, the write-only-this-file rule, an Inconclusive object for an unanswerable sub-question, repo-relative paths with no secret in an excerpt, and the pointer to the code map section" {
  local section
  section="$(section_of "$CLARIFY_LOOP" '## 5e. Research subagent dispatch')"
  require_text "5e section" "$section"
  local literal
  for literal in \
    'pre-clears one absolute output path' \
    '`rm -f`' \
    'JSON array' \
    'exactly one object per sub-question' \
    'Write tool' \
    'Wrote <n> entries to <path>' \
    'never any file in the SPEC folder, `CODE-MAP.json` included' \
    'whose `answer` begins `Inconclusive:`' \
    'repo-relative (no leading slash, no worktree prefix)' \
    'never copies a secret or token value' \
    '`## The code map`'; do
    grep -qF -- "$literal" <<<"$section" || { echo "5e prompt lacks: $literal" >&2; return 1; }
  done
  # The key list has one owner; 5e points at it and adds only the one requirement agents trip on.
  grep -qF -- '"commit"' <<<"$section" && return 1
  grep -qF -- 'every `files[]` entry carries a `lines` string `<start>-<end>`, digits only and never empty' <<<"$section" || { echo "5e prompt lacks the lines requirement" >&2; return 1; }
  grep -qF -- 'keep the `lines` range' <<<"$section" || { echo "5e prompt lacks the keep-the-range clause" >&2; return 1; }
  true
}

@test "5e classifies the research file at the sub-question count, folds from the file, appends with a read-back, takes the scratchpad-and-cp route from a linked worktree, and stops on detector exit 2 surfacing stderr with no re-dispatch" {
  local five code_map
  five="$(section_of "$CLARIFY_LOOP" '## 5e. Research subagent dispatch')"
  code_map="$(section_of "$CLARIFY_LOOP" '## The code map')"
  require_text "5e section" "$five"
  require_text "code map section" "$code_map"
  grep -qF -- 'reads the file, never the reply' <<<"$five" || return 1
  grep -qF -- 'audit-noop-detect.sh --shape agent-report-file --path <file> --expect-count <the number of sub-questions written into the prompt>' <<<"$five" || return 1
  grep -qF -- 'folded into `research_summary`' <<<"$five" || return 1
  grep -qF -- 'appended to `CODE-MAP.json` per `## The code map`' <<<"$five" || return 1
  grep -qF -- 'Exit 2 is a caller bug: stop and surface the detector'"'"'s stderr. It is never a no-op and gets no re-dispatch.' <<<"$five" || return 1
  grep -qF -- 'reads it back and confirms it equals prior plus new' <<<"$code_map" || return 1
  grep -qF -- 'Write into the session scratchpad, then one plain `cp`; never a heredoc or redirect' <<<"$code_map" || return 1
  grep -qF -- 'CODE-MAP.sha256' <<<"$code_map" || return 1
  true
}

@test "an unusable research file gets both notices, one re-dispatch, then inline research, and clarify-loop is on the no-op roster" {
  local five
  five="$(section_of "$CLARIFY_LOOP" '## 5e. Research subagent dispatch')"
  require_text "5e section" "$five"
  grep -qF -- 'Research left no usable answer; asking once more.' <<<"$five" || return 1
  grep -qF -- 'Research left no usable answer again; answering it here instead.' <<<"$five" || return 1
  grep -qF -- 'dispatch the same research once more' <<<"$five" || return 1
  grep -qF -- 'No question is asked on either path.' <<<"$five" || return 1
  # The terminal sentence is the one the no-op roster suite derives: it ends inline.
  local segment
  segment="$(grep -oE 'second no-op.*' <<<"$five" | sed 's/\. .*//')"
  require_text "the second no-op sentence" "$segment"
  grep -qF -- 'inline' <<<"$segment" || return 1
  grep -qF -- 'stop and surface' <<<"$segment" && return 1
  grep -qF -- "'.claude/skills/gaia/references/spec/clarify-loop.md'" "$ROSTER_SUITE"
}

@test "5e derives Found, Inconclusive and Contradictory from the entries' answer words, Contradictory first" {
  local five
  five="$(section_of "$CLARIFY_LOOP" '## 5e. Research subagent dispatch')"
  require_text "5e section" "$five"
  grep -qF -- "from the entries' \`answer\` leading words, not from the reply" <<<"$five" || return 1
  grep -qF -- 'any `Contradictory:` takes Contradictory (it wins over Inconclusive), else any `Inconclusive:` takes Inconclusive, else Found' <<<"$five" || return 1
  local found_line inconclusive_line error_line contradictory_line
  found_line="$(grep -nF -- '- **Found' <<<"$five" | cut -d: -f1)"
  inconclusive_line="$(grep -nF -- '- **Inconclusive' <<<"$five" | cut -d: -f1)"
  error_line="$(grep -nF -- '- **Error' <<<"$five" | cut -d: -f1)"
  contradictory_line="$(grep -nF -- '- **Contradictory' <<<"$five" | cut -d: -f1)"
  [ "$found_line" -lt "$inconclusive_line" ] || return 1
  [ "$inconclusive_line" -lt "$error_line" ] || return 1
  [ "$error_line" -lt "$contradictory_line" ] || return 1
}

@test "the code map validation program accepts a valid file and refuses every malformed entry" {
  local program fixtures
  program="$(validation_program)"
  require_text "validation program" "$program"
  fixtures="$BATS_TEST_TMPDIR/fixtures"
  mkdir -p "$fixtures"

  local valid_file='{"q":"Q?","question":"sub","commit":"abc1234","files":[{"path":"a/b.md","lines":"1-3","excerpt":"x\ny\nz\n"}],"answer":"Found: yes."}'
  local inconclusive='{"q":"Q?","question":"sub2","commit":"abc1234","files":[],"answer":"Inconclusive: nothing."}'
  printf '[%s,%s]\n' "$valid_file" "$inconclusive" >"$fixtures/valid.json"
  jq -e "$program" "$fixtures/valid.json" >/dev/null || { echo "valid file refused" >&2; return 1; }

  # Each malformed case is a jq edit of the first entry of the valid file.
  local name edit
  while IFS='|' read -r name edit; do
    jq "$edit" "$fixtures/valid.json" >"$fixtures/$name.json"
    if jq -e "$program" "$fixtures/$name.json" >/dev/null; then
      echo "malformed case accepted: $name" >&2
      return 1
    fi
  done <<'CASES'
absolute-path|.[0].files[0].path = "/etc/passwd"
parent-segment|.[0].files[0].path = "../x.md"
home-path|.[0].files[0].path = "~/x.md"
worktree-prefix|.[0].files[0].path = ".claude/worktrees/w/x.md"
four-line-excerpt|.[0].files[0].excerpt = "a\nb\nc\nd"
six-files|.[0].files = [range(6) as $i | .[0].files[0]]
extra-key|.[0].note = "x"
missing-files|del(.[0].files)
no-outcome-word|.[0].answer = "Yes."
not-an-array|.[0]
CASES
}

@test "a failed append keeps the fold and the prior map, and an unreadable map is replaced, each with its notice" {
  local code_map
  code_map="$(section_of "$CLARIFY_LOOP" '## The code map')"
  require_text "code map section" "$code_map"
  grep -qF -- 'retry the write once' <<<"$code_map" || return 1
  grep -qF -- '`research_summary` keeps the folded answer' <<<"$code_map" || return 1
  grep -qF -- 'are left exactly as they were before the append' <<<"$code_map" || return 1
  grep -qF -- 'The code map was not updated; the spec continues without it.' <<<"$code_map" || return 1
  grep -qF -- 'do not append to it: show `The code map was unreadable and was replaced with this research.`' <<<"$code_map" || return 1
  grep -qF -- 'write the current dispatch'"'"'s entries as the whole map with a fresh record' <<<"$code_map" || return 1
  grep -qF -- 'note the lost entries in `research_summary`' <<<"$code_map" || return 1
}

@test "the Error outcome covers only an Agent call error and rule 7 sends an unusable file to re-dispatch first" {
  local five error_bullet rule_seven
  five="$(section_of "$CLARIFY_LOOP" '## 5e. Research subagent dispatch')"
  error_bullet="$(grep -F -- '- **Error' <<<"$five")"
  require_text "Error bullet" "$error_bullet"
  grep -qF -- 'the Agent tool call itself returned an error' <<<"$error_bullet" || return 1
  grep -qF -- 'AskUserQuestion' <<<"$error_bullet" || return 1
  grep -qF -- 'An unusable research file never reaches this outcome' <<<"$error_bullet" || return 1
  grep -qF -- 'plain prompt' <<<"$error_bullet" && return 1
  rule_seven="$(grep -F -- '7. **Research subagents still dispatch.**' "$SPEC_PLAYBOOK")"
  require_text "auto mode rule 7" "$rule_seven"
  grep -qF -- 'An unusable research file is not one of these outcomes: it takes 5e'"'"'s re-dispatch-then-inline path first, and the most-plausible-candidate pick never applies to it.' <<<"$rule_seven" || return 1
}
