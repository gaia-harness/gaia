#!/usr/bin/env bats
#
# Doc-conformance suite for the shape of `/gaia-spec`'s playbook: the entry
# file .claude/skills/gaia/references/spec.md plus the sub-references under
# .claude/skills/gaia/references/spec/ that it reads at their branch points.
#
# The invariants:
#   a. a sub-reference read is a step a model can skip, so every spec/<name>.md
#      that spec.md names exists and is listed in the command's sub-reference
#      index (.claude/commands/gaia-spec.md), and each sub-reference moved out
#      of spec.md has a `Read` line there;
#   b. each moved section lives in exactly one file of the playbook set;
#   c. every closed-set menu fits AskUserQuestion: no Other label, no save
#      escape, and no more than four entries;
#   d. the SPEC audit refuter marks an overstated severity `partial`, refutes
#      a finding only when every gap it names fails, and never refutes a
#      missing server-only rule for a held value, or lowers it below major, on
#      ownership or a cookie or transport attribute;
#   e. the clarify loop tells the SPEC to cite the requirements file in the
#      `REQUIREMENTS.md § <heading text>` form drop-check-lib.mjs parses.
#
# Assertion style: .claude/rules/bats-assertions.md.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  PLAYBOOK_ROOT="$REPO_ROOT"
}

REFERENCES='.claude/skills/gaia/references'
COMMAND='.claude/commands/gaia-spec.md'

# The sub-references the split moved out of spec.md; each needs a Read line.
MOVED_SUB_REFERENCES=(resume.md clarify-loop.md audit.md)

# playbook_files <root>: spec.md first, then every spec/*.md, one per line.
playbook_files() {
  local root="$1" file
  [ -f "$root/$REFERENCES/spec.md" ] || return 1
  printf '%s\n' "$root/$REFERENCES/spec.md"
  for file in "$root/$REFERENCES"/spec/*.md; do
    [ -f "$file" ] && printf '%s\n' "$file"
  done
  return 0
}

# --- a. routing and the command index ----------------------------------------

# named_sub_references <root>: every spec/<name>.md spec.md names, one per line.
named_sub_references() {
  grep -oE -- '(^|[^A-Za-z0-9_-])spec/[A-Za-z0-9_-]+\.md' "$1/$REFERENCES/spec.md" | sed -E 's|^.*spec/||' | sort -u
}

sub_references_routed_and_listed() {
  local root="$1" names name count=0 expected listed=0
  names="$(named_sub_references "$root")"
  [ -n "$names" ] || return 1
  expected="$(printf '%s\n' "$names" | wc -l | tr -d ' ')"
  while IFS= read -r name; do
    count=$((count + 1))
    if [ ! -f "$root/$REFERENCES/spec/$name" ]; then
      printf 'spec.md names missing spec/%s\n' "$name" >&2
      return 1
    fi
    if ! grep -qF -- "\`$REFERENCES/spec/$name\`" "$root/$COMMAND"; then
      printf 'spec/%s is not listed in %s\n' "$name" "$COMMAND" >&2
      return 1
    fi
  done <<<"$names"
  [ "$count" -eq "$expected" ] || return 1
  for name in "${MOVED_SUB_REFERENCES[@]}"; do
    listed=$((listed + 1))
    if ! grep -qF -- "Read \`$REFERENCES/spec/$name\`" "$root/$REFERENCES/spec.md"; then
      printf 'spec/%s has no Read line in spec.md\n' "$name" >&2
      return 1
    fi
  done
  [ "$listed" -ge 1 ] || return 1
  return 0
}

# bats test_tags=whole-tree
@test "a. every sub-reference spec.md names exists, is indexed, and each moved one is routed" {
  sub_references_routed_and_listed "$PLAYBOOK_ROOT"
}

# --- b. each moved section has one owner -------------------------------------

# owner<TAB>needle<TAB>kind: kind `heading` matches a line starting with the
# needle, kind `literal` matches the needle anywhere.
OWNED=(
  "audit.md	## The critical refuter	heading"
  "audit.md	## The fixer	heading"
  "audit.md	## The drop check	heading"
  "clarify-loop.md	## 5d.	heading"
  "clarify-loop.md	## The question ceiling	heading"
  "resume.md	LOCK_STATUS=	literal"
)

holds_needle() {
  if [ "$3" = heading ]; then
    awk -v want="$2" 'index($0, want) == 1 { found = 1 } END { exit !found }' "$1"
  else
    grep -qF -- "$2" "$1"
  fi
}

sections_owned() {
  local root="$1" entry owner rest needle kind files file holders checked=0
  files="$(playbook_files "$root")" || return 1
  [ "$(printf '%s\n' "$files" | wc -l | tr -d ' ')" -ge 2 ] || return 1
  for entry in "${OWNED[@]}"; do
    owner="${entry%%	*}"
    rest="${entry#*	}"
    needle="${rest%%	*}"
    kind="${rest#*	}"
    holders=""
    while IFS= read -r file; do
      if holds_needle "$file" "$needle" "$kind"; then
        holders="$holders${file#"$root/$REFERENCES"/} "
      fi
    done <<<"$files"
    if [ "$holders" != "spec/$owner " ]; then
      printf '%s is held by [%s], expected [spec/%s]\n' "$needle" "$holders" "$owner" >&2
      return 1
    fi
    checked=$((checked + 1))
  done
  [ "$checked" -eq "${#OWNED[@]}" ] || return 1
  return 0
}

# bats test_tags=whole-tree
@test "b. each moved section lives in exactly one sub-reference" {
  sections_owned "$PLAYBOOK_ROOT"
}

# --- c. every closed-set menu fits AskUserQuestion ---------------------------

# AskUserQuestion takes at most four options and supplies its own free-text
# Other, so a menu listing Other or the save-partial escape crowds out a real
# choice, and one of five or more entries fails the call.

# menu_report <file>: one `menu <line> <entries>` line per menu, and one
# `explicit <line>` line per listed Other or save-partial entry: a label, or a
# numbered item whose text opens with the option name and its `,` or `:`
# delimiter, so a prose rule that merely names the escape is not one. A menu is a run
# of `- \`{ label:` lines, or the numbered lines under an `Options:` line, where
# a line indented five or more spaces continues the entry above it.
menu_report() {
  awk '
    function flush() {
      if (run > 0) printf "menu %d %d\n", start, run
      run = 0
    }
    /\{ label: "(Other|Save partial)/ { printf "explicit %d\n", FNR }
    /^[[:space:]]*([0-9]+|N(-[0-9]+)?)\.[[:space:]]+(\*\*)?`?(Other|Save partial and resume later)`?(\*\*)?[,:]/ { printf "explicit %d\n", FNR }
    /^[[:space:]]*- `\{ label:/ { if (run == 0) start = FNR; run++; next }
    in_options && /^[[:space:]]+([0-9]+|N(-[0-9]+)?)\.[[:space:]]/ { if (run == 0) start = FNR; run++; next }
    in_options && /^[[:space:]][[:space:]][[:space:]][[:space:]][[:space:]]+[^[:space:]]/ { next }
    /^[[:space:]]*Options:[[:space:]]*$/ { flush(); in_options = 1; next }
    { flush(); in_options = 0 }
    END { flush() }
  ' "$1"
}

menus_fit() {
  local root="$1" files file report menus=0 bad=0
  files="$(playbook_files "$root")" || return 1
  while IFS= read -r file; do
    report="$(menu_report "$file")"
    [ -n "$report" ] || continue
    while read -r kind line entries; do
      if [ "$kind" = menu ]; then
        menus=$((menus + 1))
        if [ "$entries" -gt 4 ]; then
          printf '%s:%s: menu of %s entries\n' "${file#"$root"/}" "$line" "$entries" >&2
          bad=1
        fi
      else
        printf '%s:%s: lists an option the tool supplies or the menu omits\n' "${file#"$root"/}" "$line" >&2
        bad=1
      fi
    done <<<"$report"
  done <<<"$files"
  [ "$menus" -gt 0 ] || return 1
  [ "$bad" -eq 0 ]
}

# bats test_tags=whole-tree
@test "c. no closed-set menu lists Other, the save escape, or more than four entries" {
  menus_fit "$PLAYBOOK_ROOT"
}

# --- d. the refuter keeps a sound gap and a held credential's server-only rule --

REFUTER_LINE='> For each id, open the cited SPEC section and any cited file yourself and try to REFUTE it'
REFUTER_NEEDLES=(
  'Refute a finding only when every gap it names fails, not just the harm it argues'
  'a sound gap behind an overstated harm is `partial`'
  'never refuted by who owns the value or by a cookie or transport attribute'
  'its `corrected_severity` is never lowered below `major` on those grounds'
  'overstate severity (`partial` with a corrected severity, never refuted)'
)

# refuter_keeps_sound_gaps <root>: audit.md has exactly one refuter prompt
# line, and that line carries every needle.
refuter_keeps_sound_gaps() {
  local audit="$1/$REFERENCES/spec/audit.md" line count needle
  count="$(awk -v want="$REFUTER_LINE" 'index($0, want) == 1 { n++ } END { print n + 0 }' "$audit")"
  [ "$count" -eq 1 ] || { printf 'expected one refuter prompt line, found %s\n' "$count" >&2; return 1; }
  line="$(awk -v want="$REFUTER_LINE" 'index($0, want) == 1' "$audit")"
  for needle in "${REFUTER_NEEDLES[@]}"; do
    grep -qF -- "$needle" <<<"$line" || { printf 'refuter prompt lacks: %s\n' "$needle" >&2; return 1; }
  done
}

# bats test_tags=whole-tree
@test "d. the refuter keeps a sound gap and a held credential's server-only rule" {
  refuter_keeps_sound_gaps "$PLAYBOOK_ROOT"
}


@test "e. the clarify loop states the requirements pointer form the drop check parses" {
  grep -qF -- 'the literal `REQUIREMENTS.md § <heading text>`' "$PLAYBOOK_ROOT/$REFERENCES/spec/clarify-loop.md"
}
