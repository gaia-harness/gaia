#!/usr/bin/env bats
# Single ownership of the scope-resolution obligation: the sentence lives once,
# in the "Scope resolution" section of .claude/hooks/lib/audit-member-protocol.md.
#   Group 1: the protocol carries the sentence once, and every agent
#     definition sends its member to that section and carries no copy of the
#     sentence, which would drift from the protocol's.
#   Group 2: the registration page's step 1 sends the next member author to
#     the same section and carries no copy.
# Honest limit: presence and absence, not meaning and not behavior.
#
# Assertion style: .claude/rules/bats-assertions.md.

setup() {
  ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"

  # Discovered, not transcribed: a hardcoded list would stay green for a newly
  # registered member that never carries the pointer.
  AGENTS=()
  local agent
  # gaia-lint-ignore whole-tree-mark-guard: every test that uses the agent roster this collects carries the
  # per-test mark
  for agent in "$ROOT"/.claude/agents/code-audit-*.md; do
    [ -f "$agent" ] && AGENTS+=("$agent")
  done
  # An empty discovery has verified nothing; fail rather than pass vacuously.
  [ "${#AGENTS[@]}" -gt 0 ] || return 1
  PROTOCOL="$ROOT/.claude/hooks/lib/audit-member-protocol.md"
  REGISTRATION="$ROOT/wiki/concepts/Registering a Code Audit Team Member.md"
  SCOPE_POINTER='Read `<root>/.claude/hooks/lib/audit-member-protocol.md` by path and follow its "Scope resolution" section'
  REGISTRATION_POINTER='sends the member to the `## Scope resolution` section of `.claude/hooks/lib/audit-member-protocol.md`'

  OBLIGATION_LITERAL='Capture your own branch-own digest at scope resolution with `.gaia/scripts/audit-scope-digest.sh --capture`, and at marker-write time read that captured value back with `--read` and pass it as `--scope-digest`; never re-derive it in the writing call, and a rotation between the two means the review was superseded and you must be re-dispatched on the new HEAD.'
}

# --- Group 1: no agent definition carries its own copy ---------------------

# scope_section: the protocol's "## Scope resolution" section body.
scope_section() {
  awk '/^## Scope resolution$/ { inside = 1; next } inside && /^## / { exit } inside { print }' "$PROTOCOL"
}

# The absence checks below compare against OBLIGATION_LITERAL, so this pins the
# literal to the protocol's one copy: a reworded protocol sentence fails here
# instead of leaving the absence checks green against a stale literal.
@test "Group 1: the obligation literal appears exactly once in the protocol, inside its Scope resolution section" {
  local section count
  section="$(scope_section)"
  [ -n "$section" ] || { echo "no \"## Scope resolution\" section in $PROTOCOL" >&2; return 1; }
  grep -qF -- "$OBLIGATION_LITERAL" <<<"$section" || {
    echo "obligation literal missing from the protocol's Scope resolution section" >&2
    return 1
  }
  count="$(grep -cF -- "$OBLIGATION_LITERAL" "$PROTOCOL")"
  [ "$count" -eq 1 ] || {
    echo "obligation literal appears $count times in $PROTOCOL, expected exactly 1" >&2
    return 1
  }
}

# bats test_tags=whole-tree
@test "Group 1: every agent definition sends its member to that section and carries no copy of its own" {
  local agent_file count
  for agent_file in "${AGENTS[@]}"; do
    grep -qF -- "$SCOPE_POINTER" "$agent_file" || {
      echo "$agent_file does not send its member to the protocol's Scope resolution section" >&2
      return 1
    }
    count="$(grep -cF -- "$OBLIGATION_LITERAL" "$agent_file" || true)"
    [ "$count" -eq 0 ] || {
      echo "$agent_file carries its own copy of the obligation literal, which can drift from the protocol's" >&2
      return 1
    }
  done
}

# --- Group 2: the registration page points at the protocol section ---------

# registration_step_one_points_to_protocol <page>: the page's step-1 section
# sends the next member author to the protocol's Scope resolution section and
# carries no copy of the obligation literal, which would drift from the
# protocol's one copy. Fails loudly when the step-1 heading matches nothing,
# so a renamed heading never passes vacuously.
registration_step_one_points_to_protocol() {
  local section
  section="$(awk '
    /^### 1\. / { found=1; print; next }
    found && /^### / { exit }
    found { print }
  ' "$1")"
  [ -n "$section" ] || {
    echo "step-1 heading matched nothing in $1" >&2
    return 1
  }
  printf '%s\n' "$section" | grep -qF -- "$REGISTRATION_POINTER" || {
    echo "$1 step 1 does not send the member to the protocol's Scope resolution section" >&2
    return 1
  }
  printf '%s\n' "$section" | grep -qF -- "$OBLIGATION_LITERAL" && {
    echo "$1 step 1 carries its own copy of the obligation literal" >&2
    return 1
  }
  true
}

@test "Group 2: the registration page's step 1 points at the protocol section and carries no copy" {
  registration_step_one_points_to_protocol "$REGISTRATION"
}
