#!/usr/bin/env bats
#
# Doc-conformance suite for the Code Audit Team member definitions and the
# shared member protocol they point at.
#
# What it guards. The protocol file ships to adopters (it is absent from the
# release-exclude list), its maintainer-only markers are balanced, neither it nor
# the frontend definition leaks a maintainer-only name outside a marker block, and
# the frontend definition stays inside a byte budget so the text is removed, not
# merely moved (UAT-041).
#
# Assertion style: .claude/rules/bats-assertions.md.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  PROTOCOL="$REPO_ROOT/.claude/hooks/lib/audit-member-protocol.md"
  RELEASE_EXCLUDE="$REPO_ROOT/.gaia/release-exclude"
  FRONTEND="$REPO_ROOT/.claude/agents/code-audit-frontend.md"
  PROTOCOL_PATH='.claude/hooks/lib/audit-member-protocol.md'
}

# strip_maintainer_blocks <file>: prints the file without its maintainer-only
# marker blocks, the text an adopter's scrubbed copy carries.
strip_maintainer_blocks() {
  awk '
    index($0, "<!-- gaia:maintainer-only:start -->") { inside = 1; next }
    index($0, "<!-- gaia:maintainer-only:end -->") { inside = 0; next }
    !inside { print }
  ' "$1"
}

# --- UAT-009: the shared protocol ships and keeps its markers ------------------

@test "UAT-009: the protocol ships: it is absent from the release-exclude list" {
  [ -s "$RELEASE_EXCLUDE" ] || return 1
  grep -qxF -- "$PROTOCOL_PATH" "$RELEASE_EXCLUDE" && { echo "$PROTOCOL_PATH is still release-excluded" >&2; return 1; }
  true
}

@test "the protocol's maintainer-only markers are balanced and alternate" {
  local unbalanced
  unbalanced="$(awk '
    index($0, "<!-- gaia:maintainer-only:start -->") { if (inside) { print NR; exit } inside = 1; next }
    index($0, "<!-- gaia:maintainer-only:end -->") { if (!inside) { print NR; exit } inside = 0; next }
    END { if (inside) print "EOF" }
  ' "$PROTOCOL")"
  [ -z "$unbalanced" ] || { echo "marker imbalance at $unbalanced" >&2; return 1; }
}

@test "the protocol and the frontend definition name no maintainer-only member or excluded path outside marker blocks" {
  local shipped_file hits
  for shipped_file in "$PROTOCOL" "$FRONTEND"; do
    hits="$(strip_maintainer_blocks "$shipped_file" | grep -nE -- 'code-audit-maintainer-(shell|node)|\.gaia/tests/|\.gaia/cli/src' || true)"
    [ -z "$hits" ] || { echo "$shipped_file: $hits" >&2; return 1; }
  done
}

# --- UAT-041: the byte budget -------------------------------------------------

@test "UAT-041: the frontend definition is at most 70,000 bytes and with the protocol at most 100,000" {
  local frontend_bytes protocol_bytes
  frontend_bytes="$(wc -c <"$FRONTEND" | tr -d ' ')"
  protocol_bytes="$(wc -c <"$PROTOCOL" | tr -d ' ')"
  [ "$frontend_bytes" -gt 0 ] && [ "$protocol_bytes" -gt 0 ] || return 1
  [ "$frontend_bytes" -le 70000 ] || { echo "frontend definition is $frontend_bytes bytes" >&2; return 1; }
  [ $((frontend_bytes + protocol_bytes)) -le 100000 ] || { echo "frontend plus protocol is $((frontend_bytes + protocol_bytes)) bytes" >&2; return 1; }
}
