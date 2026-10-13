#!/usr/bin/env bats
# The 2.0.0 release fence (SPEC-092 contracts C9 and C10).
#
# v1.6.1's /update-gaia downloads with `--pattern "gaia-${tag}.tar.gz"`. The 2.x
# manifest is keyed on frontend/ paths, so a 1.6.1 merge against it would read
# every baseline app path as an upstream deletion. The fence is the asset name:
# 2.x publishes `gaia-bundle-${TAG}.tar.gz`, which that glob cannot match, so
# 1.6.1 stops at its fetch step before it writes anything.
#
#   A1-A5  the asset name in release.yml, the 2.x /update-gaia pattern (read
#          from the SKILL.md Step 3c download block), and the glob semantics
#          that make the fence hold. A2 and A3 drive the failing state: the
#          retired name is matched by v1.6.1's pattern, and a pattern that
#          drifts from the upload name is reported.
#   B1-B6  the 1.x baseline refusal in SKILL.md Step 3b: the printed
#          download-and-verify command equals the routing line's, agrees with
#          the 2.0.0 note's own Step 2, and works and fails closed when run.
#   C1-C5  .gaia/scripts/compose-release-body.sh, which puts the routing line
#          first in the release body.
#
# Assertion style per .claude/rules/bats-assertions.md: no bare mid-test
# [[ ... ]]; POSIX [ ] and grep, `case` for glob matching.
#
# Maintainer-only. `.gaia/tests` is wholesale release-excluded.

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
  RELEASE_YML="$REPO_ROOT/.github/workflows/release.yml"
  SKILL="$REPO_ROOT/.claude/skills/update-gaia/SKILL.md"
  COMPOSE="$REPO_ROOT/.gaia/scripts/compose-release-body.sh"
  ROUTING_LINE="$(bash "$COMPOSE" --routing-line)"
}

# The retired routing line, assembled from parts so no tracked file holds it.
retired_routing_line() {
  printf '%s %s%s %s' 'On GAIA 1.6.1? Choose Abort,' 'then paste the prompt from https://gaiareact.com' '/migrate' 'into a fresh session.'
}

# The URL-absence token, assembled so this suite never matches itself.
migrate_url_token() {
  printf '%s/%s' gaiareact.com migrate
}

# 0 when the routing line `$1` carries every content requirement; 1 on the
# first one it lacks.
routing_line_has_content() {
  line="$1"
  for needle in \
    'choose Abort' \
    'only after the user says yes' \
    "gh release download v2.0.0 --repo gaia-react/gaia --pattern 'gaia-bundle-v2.0.0.tar.gz*' --dir .gaia/local/cache/shared/migrate-2/v2.0.0" \
    'shasum -a 256 -c' \
    '-C .gaia/local/cache/shared/migrate-2/v2.0.0/tree' \
    'tree/.gaia/migrations/2.0.0.md' \
    'Reading this on GitHub?'; do
    printf '%s' "$line" | grep -qF -- "$needle" || return 1
  done
  printf '%s' "$line" | grep -qF -- "$(migrate_url_token)" && return 1
  return 0
}

# The first argument of the `gh release create` call in a workflow file: the
# tarball name the release uploads, as a template with ${TAG} left unexpanded.
uploaded_asset_name() {
  awk '
    /^[[:space:]]*gh release create / { armed = 1; next }
    armed { gsub(/^[[:space:]]+/, ""); sub(/[[:space:]]*\\$/, ""); gsub(/"/, ""); print; exit }
  ' "$1"
}

# The first --pattern a /update-gaia Step 3c download passes, with ${tag} left
# unexpanded. The block puts each pattern on its own line, tarball first; a
# line holding both would make this greedy match return the .sha256 name.
update_pattern() {
  sed -n 's/^.*--pattern "\(gaia[^"]*\)".*$/\1/p' "$1" | head -n 1
}

# 0 when the glob `$1` (what `gh release download --pattern` evaluates) matches
# the file name `$2`.
glob_matches() {
  # The pattern is a glob on purpose: that is what `gh release download
  # --pattern` evaluates.
  # shellcheck disable=SC2254
  case "$2" in
    $1) return 0 ;;
  esac
  return 1
}

# The fenced bash block that follows the heading line `$2` in file `$1`.
block_after_heading() {
  awk -v heading="$2" '
    index($0, heading) == 1 { seen = 1; next }
    seen && /^```bash$/ { inside = 1; next }
    seen && inside && /^```$/ { exit }
    seen && inside { print }
  ' "$1"
}

@test "A1: release.yml uploads gaia-bundle-<tag>.tar.gz and its sha256" {
  name="$(uploaded_asset_name "$RELEASE_YML")"
  [ "$name" = 'gaia-bundle-${TAG}.tar.gz' ]
  grep -qF -- 'gaia-bundle-${TAG}.tar.gz.sha256' "$RELEASE_YML"
  grep -qF -- 'shasum -a 256' "$RELEASE_YML"
  # The retired name must not survive as a tar or upload target.
  grep -qE -- '"gaia-\$\{TAG\}\.tar\.gz"' "$RELEASE_YML" && return 1
  true
}

@test "A2: v1.6.1's pattern cannot match the 2.x asset, and can match the retired name" {
  TAG=v2.0.0
  new_name="gaia-bundle-${TAG}.tar.gz"
  v1_pattern="gaia-${TAG}.tar.gz"
  glob_matches "$v1_pattern" "$new_name" && return 1
  # Control: the same matcher on the retired name matches, so a pass above is
  # the name's doing and not a matcher that never matches anything.
  glob_matches "$v1_pattern" "gaia-${TAG}.tar.gz"
}

@test "A3: a release.yml that still uploads the retired name is reported" {
  fixture="$BATS_TEST_TMPDIR/old-release.yml"
  sed 's/gaia-bundle-/gaia-/g' "$RELEASE_YML" > "$fixture"
  TAG=v2.0.0
  old_name="$(uploaded_asset_name "$fixture")"
  [ "$old_name" = 'gaia-${TAG}.tar.gz' ]
  expanded="gaia-${TAG}.tar.gz"
  # v1.6.1's pattern matches the retired upload: the failure the fence prevents.
  glob_matches "gaia-${TAG}.tar.gz" "$expanded"
  # And the real workflow's name is a different string.
  [ "$(uploaded_asset_name "$RELEASE_YML")" != "$old_name" ]
}

@test "A4: the /update-gaia Step 3c pattern equals the upload name, and drift is reported" {
  block="$(block_after_heading "$SKILL" '## Step 3c')"
  [ -n "$block" ]
  printf '%s\n' "$block" > "$BATS_TEST_TMPDIR/step-3c.sh"
  pattern="$(update_pattern "$BATS_TEST_TMPDIR/step-3c.sh")"
  [ -n "$pattern" ]
  # Both templates name the tag differently (${tag} and ${TAG}); compare shapes.
  normalized_pattern="$(printf '%s' "$pattern" | sed 's/\${tag}/${TAG}/g')"
  [ "$normalized_pattern" = "$(uploaded_asset_name "$RELEASE_YML")" ]
  # The checksum asset is fetched too, on a line of its own.
  printf '%s\n' "$block" | grep -qE -- '^[[:space:]]*--pattern "gaia-bundle-\$\{tag\}\.tar\.gz\.sha256" \\$'
  # Failing state: a pattern with the retired name reads as drift.
  drifted="$BATS_TEST_TMPDIR/step-3c-drifted.sh"
  sed 's/gaia-bundle-/gaia-/g' "$BATS_TEST_TMPDIR/step-3c.sh" > "$drifted"
  drifted_pattern="$(update_pattern "$drifted" | sed 's/\${tag}/${TAG}/g')"
  [ "$drifted_pattern" != "$(uploaded_asset_name "$RELEASE_YML")" ]
  # Failing state: both patterns joined on one line return the .sha256 name,
  # which is why the block keeps one pattern per line.
  joined="$BATS_TEST_TMPDIR/step-3c-joined.sh"
  awk '
    /--pattern "gaia-bundle-\$\{tag\}\.tar\.gz" \\$/ { sub(/ \\$/, ""); held = $0; next }
    held != "" { sub(/^[[:space:]]*/, " "); print held $0; held = ""; next }
    { print }
  ' "$BATS_TEST_TMPDIR/step-3c.sh" > "$joined"
  [ "$(update_pattern "$joined")" = 'gaia-bundle-${tag}.tar.gz.sha256' ]
}

@test "A5: the Step 3c extract uses --strip-components, so the staging directory name never shows" {
  block="$(block_after_heading "$SKILL" '## Step 3c')"
  printf '%s\n' "$block" | grep -qF -- '--strip-components=1'
  grep -qF -- 'tar -czf "gaia-bundle-${TAG}.tar.gz" -C /tmp "gaia-${TAG}"' "$RELEASE_YML"
}

# The command between the first pair of backticks in the routing line.
routing_line_command() {
  printf '%s\n' "$ROUTING_LINE" | sed -n 's/^[^`]*`\([^`]*\)`.*$/\1/p'
}

# The command the refusal prints: the line it indents by two spaces.
refusal_command() {
  printf '%s\n' "$1" | sed -n 's/^  \(mkdir -p .*\)$/\1/p' | head -n 1
}

@test "B1: a 1.6.1 baseline is refused with the routing line's download-and-verify command" {
  block="$(block_after_heading "$SKILL" '## Step 3b')"
  [ -n "$block" ]
  run env BASELINE=1.6.1 bash -c "$block"
  [ "$status" -eq 1 ]
  printf '%s' "$output" | grep -qF 'REFUSED'
  printf '%s' "$output" | grep -qF '.gaia/local/cache/shared/migrate-2/v2.0.0/tree/.gaia/migrations/2.0.0.md'
  command_line="$(refusal_command "$output")"
  expected="$(routing_line_command)"
  [ -n "$expected" ]
  [ "$command_line" = "$expected" ]
  # Verification runs before extraction, and the extract lands in the note's tree.
  verify_at="$(printf '%s' "$command_line" | awk '{ print index($0, "shasum -a 256 -c") }')"
  extract_at="$(printf '%s' "$command_line" | awk '{ print index($0, "tar -xzf") }')"
  [ "$verify_at" -gt 0 ]
  [ "$extract_at" -gt "$verify_at" ]
  printf '%s' "$command_line" | grep -qF -- '-C .gaia/local/cache/shared/migrate-2/v2.0.0/tree'
  printf '%s' "$output" | grep -qF -- "$(migrate_url_token)" && return 1
  true
}

@test "B2: a 2.0.0 baseline proceeds silently" {
  block="$(block_after_heading "$SKILL" '## Step 3b')"
  run env BASELINE=2.0.0 bash -c "$block"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "B3: a malformed baseline is refused, never read as proceed" {
  block="$(block_after_heading "$SKILL" '## Step 3b')"
  for bad in '' 'v2.0.0' 'abc' '1x.0.0'; do
    run env BASELINE="$bad" bash -c "$block"
    [ "$status" -eq 1 ]
  done
}

@test "B4: the refusal block creates no branch and precedes every branch and download outside it" {
  block="$(block_after_heading "$SKILL" '## Step 3b')"
  printf '%s' "$block" | grep -qF 'checkout -b' && return 1
  printf '%s' "$block" | grep -qF 'git switch' && return 1
  refusal_line="$(grep -n '^## Step 3b' "$SKILL" | head -n 1 | cut -d: -f1)"
  refusal_end="$(awk -v start="$refusal_line" 'NR > start && /^```$/ { print NR; exit }' "$SKILL")"
  branch_line="$(grep -n 'git checkout -b' "$SKILL" | head -n 1 | cut -d: -f1)"
  switch_line="$(grep -n 'git switch' "$SKILL" | head -n 1 | cut -d: -f1)"
  download_line="$(grep -n 'gh release download' "$SKILL" |
    awk -F: -v start="$refusal_line" -v end="$refusal_end" '$1 < start || $1 > end { print $1; exit }')"
  [ -n "$refusal_line" ]
  [ -n "$refusal_end" ]
  [ -n "$branch_line" ]
  [ -n "$switch_line" ]
  [ -n "$download_line" ]
  [ "$refusal_line" -lt "$branch_line" ]
  [ "$refusal_line" -lt "$switch_line" ]
  [ "$refusal_line" -lt "$download_line" ]
}

# The `## Step 2` section of a 2.0.0 note.
note_step_2() {
  awk '/^## Step 2/ { inside = 1; print; next } inside && /^## / { exit } inside { print }' "$1"
}

# 0 when every asset name and the cache directory in command `$1` appear in
# the Step 2 of note `$2`.
note_agrees_with_command() {
  local step_2 needle
  step_2="$(note_step_2 "$2")"
  [ -n "$step_2" ] || return 1
  for needle in 'gaia-bundle-v2.0.0.tar.gz' 'gaia-bundle-v2.0.0.tar.gz.sha256' '.gaia/local/cache/shared/migrate-2/v2.0.0'; do
    printf '%s' "$1" | grep -qF -- "$needle" || return 1
    printf '%s' "$step_2" | grep -qF -- "$needle" || return 1
  done
}

@test "B5: the refusal's assets and cache directory match the 2.0.0 note's Step 2, and drift is reported" {
  block="$(block_after_heading "$SKILL" '## Step 3b')"
  run env BASELINE=1.6.1 bash -c "$block"
  command_line="$(refusal_command "$output")"
  [ -n "$command_line" ]
  note="$REPO_ROOT/.gaia/migrations/2.0.0.md"
  note_agrees_with_command "$command_line" "$note"
  # Failing state: a note that caches the bundle elsewhere.
  drifted="$BATS_TEST_TMPDIR/2.0.0-drifted.md"
  sed 's|cache/shared/migrate-2/v2.0.0|cache/shared/migrate-two/v2.0.0|g' "$note" > "$drifted"
  note_agrees_with_command "$command_line" "$drifted" && return 1
  true
}

# A stub gh that copies the fixture release assets into the --dir it is given.
write_fixture_gh() {
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  cat > "$BATS_TEST_TMPDIR/bin/gh" <<'STUB'
#!/usr/bin/env bash
target=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --dir) target="$2"; shift 2 ;;
    *) shift ;;
  esac
done
[ -n "$target" ] || exit 1
mkdir -p "$target"
cp "$FIXTURE_ASSETS"/* "$target"/
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/gh"
}

# Builds the v2.0.0 fixture tarball holding the note, and its checksum file.
write_fixture_release() {
  local stage="$BATS_TEST_TMPDIR/stage" hex
  mkdir -p "$stage/gaia-v2.0.0/.gaia/migrations" "$FIXTURE_ASSETS"
  printf -- '---\nmode: blocking\n---\n\n# fixture note\n' > "$stage/gaia-v2.0.0/.gaia/migrations/2.0.0.md"
  tar -czf "$FIXTURE_ASSETS/gaia-bundle-v2.0.0.tar.gz" -C "$stage" gaia-v2.0.0
  hex="$(shasum -a 256 "$FIXTURE_ASSETS/gaia-bundle-v2.0.0.tar.gz" | awk '{ print $1 }')"
  printf '%s  gaia-bundle-v2.0.0.tar.gz\n' "$hex" > "$FIXTURE_ASSETS/gaia-bundle-v2.0.0.tar.gz.sha256"
}

@test "B6: the printed command downloads, verifies and extracts the note, and fails closed on a bad checksum" {
  block="$(block_after_heading "$SKILL" '## Step 3b')"
  run env BASELINE=1.6.1 bash -c "$block"
  command_line="$(refusal_command "$output")"
  [ -n "$command_line" ]
  export FIXTURE_ASSETS="$BATS_TEST_TMPDIR/assets"
  write_fixture_release
  write_fixture_gh
  note_path='.gaia/local/cache/shared/migrate-2/v2.0.0/tree/.gaia/migrations/2.0.0.md'

  work="$BATS_TEST_TMPDIR/project"
  mkdir -p "$work"
  run env PATH="$BATS_TEST_TMPDIR/bin:$PATH" bash -c 'cd "$1" || exit 99; eval "$2"' _ "$work" "$command_line"
  [ "$status" -eq 0 ]
  [ -f "$work/$note_path" ]

  # Failing state: a checksum that does not match the tarball.
  printf '%064d  gaia-bundle-v2.0.0.tar.gz\n' 0 > "$FIXTURE_ASSETS/gaia-bundle-v2.0.0.tar.gz.sha256"
  tampered="$BATS_TEST_TMPDIR/tampered"
  mkdir -p "$tampered"
  run env PATH="$BATS_TEST_TMPDIR/bin:$PATH" bash -c 'cd "$1" || exit 99; eval "$2"' _ "$tampered" "$command_line"
  [ "$status" -ne 0 ]
  [ -e "$tampered/$note_path" ] && return 1
  [ -d "$tampered/.gaia/local/cache/shared/migrate-2/v2.0.0/tree" ]
}

@test "C1: the composed body starts with the routing line and carries the sha256" {
  notes="$BATS_TEST_TMPDIR/notes.md"
  sha="$BATS_TEST_TMPDIR/asset.sha256"
  out="$BATS_TEST_TMPDIR/body.md"
  printf '## [2.0.0] - 2026-10-03\n\n### Breaking\n\n%s\n\n- the entry\n' "$ROUTING_LINE" > "$notes"
  printf 'deadbeef  gaia-bundle-v2.0.0.tar.gz\n' > "$sha"
  run bash "$COMPOSE" v2.0.0 "$notes" "$sha" "$out"
  [ "$status" -eq 0 ]
  [ "$(head -n 1 "$out")" = "$ROUTING_LINE" ]
  grep -qF 'deadbeef  gaia-bundle-v2.0.0.tar.gz' "$out"
  grep -qF 'FETCH_FAILED' "$out"
  # The routing line appears once: hoisted, not duplicated.
  [ "$(grep -cxF -- "$ROUTING_LINE" "$out")" -eq 1 ]
  grep -qF '## [2.0.0] - 2026-10-03' "$out"
  routing_line_has_content "$(head -n 1 "$out")"
  sed -n 3p "$out" | grep -qF 'Choosing Proceed on 1.6.1'
  grep -qxF 'sha256: deadbeef  gaia-bundle-v2.0.0.tar.gz' "$out"
}

@test "C1b: --routing-line prints exactly the one line and exits 0" {
  run bash "$COMPOSE" --routing-line
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" -eq 1 ]
  routing_line_has_content "$output"
}

@test "C1c: the content check fails on a line without the yes-gate and on the retired line" {
  routing_line_has_content "$ROUTING_LINE"
  without_gate="${ROUTING_LINE//only after the user says yes/now}"
  [ "$without_gate" != "$ROUTING_LINE" ]
  routing_line_has_content "$without_gate" && return 1
  routing_line_has_content "$(retired_routing_line)" && return 1
  true
}

@test "C2: v2.0.0 notes without the routing line are refused" {
  notes="$BATS_TEST_TMPDIR/notes.md"
  sha="$BATS_TEST_TMPDIR/asset.sha256"
  out="$BATS_TEST_TMPDIR/body.md"
  printf '## [2.0.0] - 2026-10-03\n\n- the entry\n' > "$notes"
  printf 'deadbeef  gaia-bundle-v2.0.0.tar.gz\n' > "$sha"
  run bash "$COMPOSE" v2.0.0 "$notes" "$sha" "$out"
  [ "$status" -eq 1 ]
  [ ! -e "$out" ]
}

@test "C2b: v2.0.0 notes carrying the retired routing line are refused" {
  notes="$BATS_TEST_TMPDIR/notes.md"
  sha="$BATS_TEST_TMPDIR/asset.sha256"
  out="$BATS_TEST_TMPDIR/body.md"
  printf '## [2.0.0] - 2026-10-03\n\n### Breaking\n\n%s\n\n- the entry\n' "$(retired_routing_line)" > "$notes"
  printf 'deadbeef  gaia-bundle-v2.0.0.tar.gz\n' > "$sha"
  run bash "$COMPOSE" v2.0.0 "$notes" "$sha" "$out"
  [ "$status" -eq 1 ]
  [ ! -e "$out" ]
}

@test "C3: an empty sha256 file is refused" {
  notes="$BATS_TEST_TMPDIR/notes.md"
  sha="$BATS_TEST_TMPDIR/asset.sha256"
  out="$BATS_TEST_TMPDIR/body.md"
  printf '## [2.1.0] - 2026-10-03\n\n- the entry\n' > "$notes"
  : > "$sha"
  run bash "$COMPOSE" v2.1.0 "$notes" "$sha" "$out"
  [ "$status" -eq 1 ]
  [ ! -e "$out" ]
}

@test "C4: a later release without the routing line gets the notes plus the sha256 line" {
  notes="$BATS_TEST_TMPDIR/notes.md"
  sha="$BATS_TEST_TMPDIR/asset.sha256"
  out="$BATS_TEST_TMPDIR/body.md"
  printf '## [2.1.0] - 2026-10-03\n\n- the entry\n' > "$notes"
  printf 'cafe  gaia-bundle-v2.1.0.tar.gz\n' > "$sha"
  run bash "$COMPOSE" v2.1.0 "$notes" "$sha" "$out"
  [ "$status" -eq 0 ]
  grep -qF 'sha256: cafe  gaia-bundle-v2.1.0.tar.gz' "$out"
  grep -qF -- '- the entry' "$out"
  grep -qF 'FETCH_FAILED' "$out" && return 1
  true
}

@test "C5: a wrong argument count is a usage error" {
  run bash "$COMPOSE" v2.0.0
  [ "$status" -eq 2 ]
}
