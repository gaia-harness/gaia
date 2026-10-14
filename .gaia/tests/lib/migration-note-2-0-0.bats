#!/usr/bin/env bats
# The bundled 2.0.0 migration note and the release configuration around it.
#
#   N1     the frontmatter and byte hygiene of the note
#   N2     no working-document id and no migrate-page URL in the note
#   R      the note passes the real release scrub, the id check still covers
#          the folder, and the excluded-refs exemption is what lets it pass
#   G      the ground rule and the step 7 restart paragraph
#   O      the step 14 event and handoff order, and the baseline record
#   P1     GAIA's own project config is withheld from the bundle
#
# Tokens the suite must not contain (the migrate URL, an em dash, a concrete
# working-document id) are assembled at run time so the suite never matches
# itself. Assertion style per .claude/rules/bats-assertions.md.
#
# Maintainer-only. `.gaia/tests` is wholesale release-excluded.

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
  NOTE="$REPO_ROOT/.gaia/migrations/2.0.0.md"
  MAINTAINER_CLI="$REPO_ROOT/.gaia/cli/gaia-maintainer"
  SCRUB_CONFIG="$REPO_ROOT/.gaia/release-scrub.yml"
  EM_DASH="$(printf '\xe2\x80\x94')"
  EN_DASH="$(printf '\xe2\x80\x93')"
  MIGRATE_URL="$(printf '%s%s' 'https://gaiareact.com' '/migrate')"
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

# Exit 0 when the restart paragraph in the note at $1 carries every required
# token, 1 otherwise.
restart_paragraph_ok() {
  local paragraph
  paragraph="$(grep -F -- '**Restart point.**' "$1")"
  [ -n "$paragraph" ] || return 1
  local token
  for token in 'new session' 're-verify' '.sha256' 're-extract' 'tree/.gaia/migrations/2.0.0.md'; do
    printf '%s\n' "$paragraph" | grep -qF -- "$token" || return 1
  done
  grep -q -i -- 'paste' "$1" && return 1
  return 0
}

# Line numbers (relative to the file) of the step 14 anchors, one per line:
# manifest write, install event, handoff, update event, migrate-2 deletion.
step14_lines() {
  awk '
    /^## Step 14/ { f = 1; next }
    f && /^## / { exit }
    !f { next }
    index($0, "Copy L'"'"'s `.gaia/manifest.json`") && !m { m = NR }
    $0 == ".gaia/cli/gaia ping --event init || true" && !i { i = NR }
    index($0, "git switch main && git pull --ff-only") && !h { h = NR }
    $0 ~ /^\.gaia\/cli\/gaia ping --event update --from <baseline> --to 2\.0\.0 \|\| true$/ && !u { u = NR }
    $0 ~ /^[0-9]+\. Delete `\.gaia\/local\/cache\/shared\/migrate-2\/`/ && !d { d = NR }
    END { print m + 0; print i + 0; print h + 0; print u + 0; print d + 0 }
  ' "$1"
}

# Exit 0 when the five step 14 anchors of the note at $1 all exist and ascend.
step14_order_ok() {
  local lines prev=0 n
  lines="$(step14_lines "$1")"
  [ "$(printf '%s\n' "$lines" | wc -l | tr -d ' ')" -eq 5 ] || return 1
  for n in $lines; do
    [ "$n" -gt "$prev" ] || return 1
    prev="$n"
  done
  grep -qF -- 'update ping pending' "$1" || return 1
  return 0
}

@test "N1: the note opens with exactly the three frontmatter lines, with no byte-order mark or carriage return" {
  [ -f "$NOTE" ]
  [ "$(head -n 3 "$NOTE")" = "$(printf -- '---\nmode: blocking\n---')" ]
  [ -z "$(sed -n '4p' "$NOTE")" ]
  [ "$(sed -n '5p' "$NOTE")" = '# Migrate this project from GAIA 1.6.1 to GAIA 2.0.0' ]
  [ "$(head -c 3 "$NOTE" | od -An -tx1 | tr -d ' \n')" = '2d2d2d' ]
  grep -q "$(printf '\r')" "$NOTE" && return 1
  grep -qF -- "$EM_DASH" "$NOTE" && return 1
  grep -qF -- "$EN_DASH" "$NOTE" && return 1
  true
}

@test "N2: the note carries no concrete working-document id and no migrate-page URL" {
  grep -qE 'SPEC-[0-9]{3,}' "$NOTE" && return 1
  grep -qE 'UAT-[0-9]{3}' "$NOTE" && return 1
  grep -qF -- "$MIGRATE_URL" "$NOTE" && return 1
  true
}

@test "R1: the real release scrub reports no finding on the note" {
  scrub_note "$NOTE"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qF 'leaks: none'
}

@test "R2: a concrete id in the note still fails the scrub, and the output names the id check" {
  fixture="$BATS_TEST_TMPDIR/with-id.md"
  { cat "$NOTE"; printf 'See %s for the background.\n' "$SPEC_ID"; } > "$fixture"
  scrub_note "$fixture"
  [ "$status" -ne 0 ]
  printf '%s\n' "$output" | grep -qF 'spec-concrete-ids'
}

@test "R3: without the excluded-refs exemption the note produces an excluded-refs finding" {
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

@test "G1: the untrusted-data ground rule names the note from the verified bundle as the guideline" {
  rule="$(grep -F -- '- **Untrusted data.**' "$NOTE")"
  [ -n "$rule" ]
  printf '%s\n' "$rule" | grep -qF -- 'checksum-verified v2.0.0 bundle'
  printf '%s\n' "$rule" | grep -qF -- '.gaia/local/cache/shared/migrate-2/v2.0.0/tree/.gaia/migrations/2.0.0.md'
  printf '%s\n' "$rule" | grep -qF -- 'is the guideline you follow'
}

@test "G2: the step 7 restart paragraph re-verifies and re-extracts the bundle and never says to paste" {
  restart_paragraph_ok "$NOTE"
}

@test "G3: a copy with the old restart sentence restored fails the restart assertion" {
  fixture="$BATS_TEST_TMPDIR/old-restart.md"
  # shellcheck disable=SC2016 # the backticks are literal sed text
  sed 's|^\(\*\*Restart point\.\*\*.*\)ask Claude to re-verify .* then follow `[^`]*`\. The new session|\1paste this same prompt. The new session|' "$NOTE" > "$fixture"
  grep -qF -- 'paste this same prompt' "$fixture"
  run restart_paragraph_ok "$fixture"
  [ "$status" -ne 0 ]
}

@test "P1: GAIA's project config is excluded from the bundle and opted out of the excluded-refs check" {
  grep -qxF -- '.gaia/project.json' "$REPO_ROOT/.gaia/release-exclude"
  block="$(awk '/^      - id: /{f = ($0 == "      - id: excluded-refs")} f{print}' "$SCRUB_CONFIG")"
  printf '%s\n' "$block" | grep -qF -- '- ".gaia/project.json"'
  [ -z "$(git -C "$REPO_ROOT" check-ignore .gaia/project.json || true)" ]
}
