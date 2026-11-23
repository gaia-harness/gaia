#!/usr/bin/env bats
# The 2.0.0 release fence.
#
# v1.6.1's /update-gaia downloads with `--pattern "gaia-${tag}.tar.gz"`. The 2.x
# manifest is keyed on apps/web/ paths, so a 1.6.1 merge against it would read
# every baseline app path as an upstream deletion. The fence is the asset name:
# 2.x publishes `gaia-bundle-${TAG}.tar.gz`, which that glob cannot match, so
# 1.6.1 stops at its fetch step before it writes anything.
#
# The suite covers the asset name in release.yml against the /update-gaia
# pattern (read from the update-gaia-preflight.sh verify-bundles code), the 1.x
# baseline refusal (update-gaia-preflight.sh refuse-1x) with its printed
# download-and-verify command, and the release body (the extracted CHANGELOG
# section, with nothing composed in front of it).
#
# Assertion style per .claude/rules/bats-assertions.md: no bare mid-test
# [[ ... ]]; POSIX [ ] and grep, `case` for glob matching.
#
# Maintainer-only. `.gaia/tests` is wholesale release-excluded.

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
  RELEASE_YML="$REPO_ROOT/.github/workflows/release.yml"
  PREFLIGHT="$REPO_ROOT/.gaia/scripts/update-gaia-preflight.sh"
}

# The URL-absence token, assembled so this suite never matches itself.
migrate_url_token() {
  printf '%s/%s' gaiareact.com migrate
}

# The first argument of the `gh release create` call in a workflow file: the
# tarball name the release uploads, as a template with ${TAG} left unexpanded.
uploaded_asset_name() {
  awk '
    /^[[:space:]]*gh release create / { armed = 1; next }
    armed { gsub(/^[[:space:]]+/, ""); sub(/[[:space:]]*\\$/, ""); gsub(/"/, ""); print; exit }
  ' "$1"
}

# The first --pattern a /update-gaia bundle download passes, with ${tag} left
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

# The body of the verify_bundles function in script `$1`.
verify_bundles_body() {
  awk '/^verify_bundles\(\) \{$/ { inside = 1; next } inside && /^}$/ { exit } inside { print }' "$1"
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

@test "the 2.x release asset name (gaia-bundle-<tag>.tar.gz and its sha256) is what release.yml uploads, what the /update-gaia verify-bundles pattern downloads and extracts, and a v1.6.1 pattern cannot match it" {
  TAG=v2.0.0
  name="$(uploaded_asset_name "$RELEASE_YML")"
  [ "$name" = 'gaia-bundle-${TAG}.tar.gz' ]
  grep -qF -- 'gaia-bundle-${TAG}.tar.gz.sha256' "$RELEASE_YML"
  grep -qF -- 'shasum -a 256' "$RELEASE_YML"
  # The retired name must not survive as a tar or upload target.
  grep -qE -- '"gaia-\$\{TAG\}\.tar\.gz"' "$RELEASE_YML" && return 1

  # v1.6.1's pattern misses the 2.x asset; the same matcher on the retired
  # name matches, so the miss is the name's doing.
  v1_pattern="gaia-${TAG}.tar.gz"
  glob_matches "$v1_pattern" "${name//'${TAG}'/$TAG}" && return 1
  glob_matches "$v1_pattern" "gaia-${TAG}.tar.gz"

  block="$(verify_bundles_body "$PREFLIGHT")"
  [ -n "$block" ]
  printf '%s\n' "$block" > "$BATS_TEST_TMPDIR/verify-bundles.sh"
  pattern="$(update_pattern "$BATS_TEST_TMPDIR/verify-bundles.sh")"
  [ -n "$pattern" ]
  # Both templates name the tag differently (${tag} and ${TAG}); compare shapes.
  normalized_pattern="$(printf '%s' "$pattern" | sed 's/\${tag}/${TAG}/g')"
  [ "$normalized_pattern" = "$name" ]
  # The checksum asset is fetched too, on a line of its own.
  printf '%s\n' "$block" | grep -qE -- '^[[:space:]]*--pattern "gaia-bundle-\$\{tag\}\.tar\.gz\.sha256" \\$'
  # The extract strips the staging directory, whose name never shows.
  printf '%s\n' "$block" | grep -qF -- '--strip-components=1'
  grep -qF -- 'tar -czf "gaia-bundle-${TAG}.tar.gz" -C /tmp "gaia-${TAG}"' "$RELEASE_YML"
}

# The command the refusal prints: the line it indents by two spaces.
refusal_command() {
  printf '%s\n' "$1" | sed -n 's/^  \(mkdir -p .*\)$/\1/p' | head -n 1
}

@test "refuse-1x refuses a 1.6.1 baseline with the download-verify-extract command for the v2.0.0 bundle, proceeds silently on 2.0.0 and refuses a malformed baseline" {
  run bash "$PREFLIGHT" refuse-1x --baseline 1.6.1
  [ "$status" -eq 1 ]
  printf '%s' "$output" | grep -qF 'REFUSED'
  printf '%s' "$output" | grep -qF '.gaia/local/cache/shared/migrate-2/v2.0.0/tree/.gaia/migrations/2.0.0.md'
  command_line="$(refusal_command "$output")"
  [ -n "$command_line" ]
  printf '%s' "$command_line" | grep -qF -- "gh release download v2.0.0 --repo gaia-react/gaia --pattern 'gaia-bundle-v2.0.0.tar.gz*' --dir .gaia/local/cache/shared/migrate-2/v2.0.0"
  # Verification runs before extraction, and the extract lands in the note's tree.
  verify_at="$(printf '%s' "$command_line" | awk '{ print index($0, "shasum -a 256 -c") }')"
  extract_at="$(printf '%s' "$command_line" | awk '{ print index($0, "tar -xzf") }')"
  [ "$verify_at" -gt 0 ]
  [ "$extract_at" -gt "$verify_at" ]
  printf '%s' "$command_line" | grep -qF -- '-C .gaia/local/cache/shared/migrate-2/v2.0.0/tree'
  printf '%s' "$output" | grep -qF -- "$(migrate_url_token)" && return 1

  run bash "$PREFLIGHT" refuse-1x --baseline 2.0.0
  [ "$status" -eq 0 ]
  [ -z "$output" ]

  for bad in '' 'v2.0.0' 'abc' '1x.0.0' 'x.y'; do
    run bash "$PREFLIGHT" refuse-1x --baseline "$bad"
    [ "$status" -eq 1 ] || { echo "baseline '$bad': status $status"; return 1; }
  done
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

# bats test_tags=protected
@test "the printed command downloads, verifies and extracts the note, and fails closed on a bad checksum" {
  run bash "$PREFLIGHT" refuse-1x --baseline 1.6.1
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

# 0 when workflow file `$1` publishes the extracted CHANGELOG section,
# release-notes.md, as the release body: the build job hands it to the publish
# job, `gh release create` reads it as the notes file, and no step composes a
# separate body.
release_body_is_notes() {
  grep -qE -- '--notes-file release-notes\.md$' "$1" || return 1
  awk '/name: release-assets/ { armed = 1 } armed && /^[[:space:]]*release-notes\.md$/ { found = 1 } END { exit !found }' "$1" || return 1
  grep -qE -- 'release-body\.md|compose-release-body' "$1" && return 1
  return 0
}

@test "the release body is the CHANGELOG section, with no 1.6.1 routing block" {
  release_body_is_notes "$RELEASE_YML"
  [ ! -e "$REPO_ROOT/.gaia/scripts/compose-release-body.sh" ]
}
