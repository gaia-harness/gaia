#!/usr/bin/env bats
# The bundled 2.0.0 migration note and the release configuration around it.
#
#   N1     the frontmatter and byte hygiene of the note
#   R      the note passes the real release scrub, the id check still covers
#          the folder, and the excluded-refs exemption is what lets it pass
#   P1     GAIA's own project config is withheld from the bundle
#
# The concrete working-document id the suite needs is assembled at run time so
# the suite never matches itself. Assertion style per .claude/rules/bats-assertions.md.
#
# Maintainer-only. `.gaia/tests` is wholesale release-excluded.

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
  NOTE="$REPO_ROOT/.gaia/migrations/2.0.0.md"
  MAINTAINER_CLI="$REPO_ROOT/.gaia/cli/gaia-maintainer"
  SCRUB_CONFIG="$REPO_ROOT/.gaia/release-scrub.yml"
  SPEC_ID="$(printf '%s%s' 'SPEC-' '123')"
}

# Run the real scrub over a staging directory holding one note, from the
# repository root so the excluded-refs derivation reads the tracked tree.
scrub_note() {
  local note="$1" config="${2:-$SCRUB_CONFIG}" staging
  staging="$(mktemp -d "$BATS_TEST_TMPDIR/staging.XXXXXX")"
  mkdir -p "$staging/.gaia/migrations"
  cp "$note" "$staging/.gaia/migrations/2.0.0.md"
  run bash -c 'cd "$1" && "$2" release scrub "$3" --config "$4"' _ "$REPO_ROOT" "$MAINTAINER_CLI" "$staging" "$config"
}

@test "N1: the note opens with exactly the three frontmatter lines, with no byte-order mark or carriage return" {
  [ -f "$NOTE" ]
  [ "$(head -n 3 "$NOTE")" = "$(printf -- '---\nmode: blocking\n---')" ]
  [ -z "$(sed -n '4p' "$NOTE")" ]
  [ "$(head -c 3 "$NOTE" | od -An -tx1 | tr -d ' \n')" = '2d2d2d' ]
  grep -q "$(printf '\r')" "$NOTE" && return 1
  true
}

# bats test_tags=protected
@test "the real release scrub reports no finding on the note, fails a concrete id naming spec-concrete-ids, and fails with an excluded-refs finding without the migrations exemption" {
  scrub_note "$NOTE"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qF 'leaks: none'

  fixture="$BATS_TEST_TMPDIR/with-id.md"
  { cat "$NOTE"; printf 'See %s for the background.\n' "$SPEC_ID"; } > "$fixture"
  scrub_note "$fixture"
  [ "$status" -ne 0 ]
  printf '%s\n' "$output" | grep -qF 'spec-concrete-ids'

  config="$BATS_TEST_TMPDIR/no-exemption.yml"
  grep -vF -- '- ".gaia/migrations/**"' "$SCRUB_CONFIG" > "$config"
  [ "$(grep -cF -- '.gaia/migrations/**' "$config")" -eq 0 ]
  scrub_note "$NOTE" "$config"
  [ "$status" -ne 0 ]
  printf '%s\n' "$output" | grep -qF 'excluded-refs'
}

@test "R4: the migrations exemption appears exactly once, inside the excluded-refs check" {
  [ "$(grep -cF -- '".gaia/migrations/**"' "$SCRUB_CONFIG")" -eq 1 ]
  block="$(awk '/^      - id: /{f = ($0 == "      - id: excluded-refs")} f{print}' "$SCRUB_CONFIG")"
  [ "$(printf '%s\n' "$block" | grep -cF -- '".gaia/migrations/**"')" -eq 1 ]
}

@test "P1: GAIA's project config is excluded from the bundle and opted out of the excluded-refs check" {
  grep -qxF -- '.gaia/project.json' "$REPO_ROOT/.gaia/release-exclude"
  block="$(awk '/^      - id: /{f = ($0 == "      - id: excluded-refs")} f{print}' "$SCRUB_CONFIG")"
  printf '%s\n' "$block" | grep -qF -- '- ".gaia/project.json"'
  [ -z "$(git -C "$REPO_ROOT" check-ignore .gaia/project.json || true)" ]
}
