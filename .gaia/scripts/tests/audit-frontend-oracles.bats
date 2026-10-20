#!/usr/bin/env bats
#
# audit-frontend-oracles.sh: the frontend member's three deterministic oracles
# run concurrently, gated by what the branch changed, behind one table.
#
# Every test builds a scratch git repository with the script copied in, a main
# base commit and a feature branch. Stubs for npx, pnpm and the gaia CLI come
# first on PATH (the CLI stub sits where the script expects it inside the
# scratch root); each appends "<name> start|end <epoch>" to a log and writes a
# canned output, so a test reads which oracles ran and in what order without a
# network, a node toolchain or a real scan. The react-doctor canned output is a
# trimmed recorded sample, so the count rule the script pins is checked against
# real output shape.
#
# Run under bash 5: `bash .gaia/scripts/bats5.sh
# .gaia/scripts/tests/audit-frontend-oracles.bats < /dev/null`.

bats_require_minimum_version 1.5.0

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  SCRIPT_SOURCE="$REPO_ROOT/.gaia/scripts/audit-frontend-oracles.sh"
  SAMPLE="$BATS_TEST_DIRNAME/fixtures/audit-frontend-oracles/react-doctor-sample.txt"
  if ! command -v jq >/dev/null 2>&1; then
    if [ -n "${GITHUB_ACTIONS:-}" ]; then
      echo "jq not present on a CI runner; the oracle table would report green" >&2
      return 1
    fi
    skip "jq required"
  fi

  SANDBOX="$BATS_TEST_TMPDIR/sandbox"
  STUB_DIR="$BATS_TEST_TMPDIR/stubs"
  OUT_DIR="$BATS_TEST_TMPDIR/out"
  export STUB_LOG="$BATS_TEST_TMPDIR/stub.log"
  : >"$STUB_LOG"
  unset STUB_SLEEP STUB_KNIP_RC STUB_KNIP_PAYLOAD STUB_ADVISORIES_PAYLOAD STUB_REACT_DOCTOR_OUTPUT

  mkdir -p "$SANDBOX/.gaia/scripts" "$SANDBOX/.gaia/cli" "$STUB_DIR"
  cp "$SCRIPT_SOURCE" "$SANDBOX/.gaia/scripts/audit-frontend-oracles.sh"
  SCRIPT="$SANDBOX/.gaia/scripts/audit-frontend-oracles.sh"

  git -C "$SANDBOX" init -q -b main
  git -C "$SANDBOX" config user.email test@example.com
  git -C "$SANDBOX" config user.name Test
  git -C "$SANDBOX" config commit.gpgsign false
  printf 'base\n' >"$SANDBOX/README.md"
  git -C "$SANDBOX" add README.md
  git -C "$SANDBOX" commit -q -m base
  BASE_SHA="$(git -C "$SANDBOX" rev-parse HEAD)"

  write_stubs
  write_default_payloads
  export PATH="$STUB_DIR:$PATH"
}

# One stub body: log the start, sleep when asked, write the canned output, log
# the end, exit with the stub's configured status.
write_stubs() {
  cat >"$STUB_DIR/npx" <<'EOF'
#!/usr/bin/env bash
echo "npx start $(date +%s)" >>"$STUB_LOG"
sleep "${STUB_SLEEP:-0}"
[ -n "${STUB_REACT_DOCTOR_OUTPUT:-}" ] && cat "$STUB_REACT_DOCTOR_OUTPUT"
echo "npx end $(date +%s)" >>"$STUB_LOG"
exit "${STUB_REACT_DOCTOR_RC:-0}"
EOF
  cat >"$STUB_DIR/pnpm" <<'EOF'
#!/usr/bin/env bash
echo "pnpm start $(date +%s)" >>"$STUB_LOG"
sleep "${STUB_SLEEP:-0}"
[ -n "${STUB_KNIP_PAYLOAD:-}" ] && cat "$STUB_KNIP_PAYLOAD"
echo "pnpm end $(date +%s)" >>"$STUB_LOG"
exit "${STUB_KNIP_RC:-0}"
EOF
  cat >"$SANDBOX/.gaia/cli/gaia" <<'EOF'
#!/usr/bin/env bash
echo "gaia start $(date +%s)" >>"$STUB_LOG"
sleep "${STUB_SLEEP:-0}"
while [ $# -gt 0 ]; do
  if [ "$1" = "--emit" ]; then
    emit=$2
  fi
  shift
done
[ -n "${STUB_ADVISORIES_PAYLOAD:-}" ] && cp "$STUB_ADVISORIES_PAYLOAD" "$emit"
echo "gaia end $(date +%s)" >>"$STUB_LOG"
exit "${STUB_ADVISORIES_RC:-0}"
EOF
  chmod +x "$STUB_DIR/npx" "$STUB_DIR/pnpm" "$SANDBOX/.gaia/cli/gaia"
}

write_default_payloads() {
  cat >"$BATS_TEST_TMPDIR/advisories.json" <<'EOF'
{
  "source": "dependabot",
  "advisories": [
    {"package": "lodash", "severity": "high", "ghsa": "GHSA-aaaa-bbbb-cccc", "key": "GHSA-aaaa-bbbb-cccc",
     "firstPatchedVersion": "4.17.21", "patchedVersions": ["4.17.21"], "baselineAcknowledged": false},
    {"package": "minimist", "severity": "critical", "ghsa": "GHSA-dddd-eeee-ffff", "key": "GHSA-dddd-eeee-ffff",
     "firstPatchedVersion": "1.2.6", "patchedVersions": ["1.2.6"], "baselineAcknowledged": true},
    {"package": "left-pad", "severity": "moderate", "ghsa": "GHSA-gggg-hhhh-iiii", "key": "GHSA-gggg-hhhh-iiii",
     "firstPatchedVersion": null, "patchedVersions": [], "baselineAcknowledged": false}
  ]
}
EOF
  cat >"$BATS_TEST_TMPDIR/knip.json" <<'EOF'
{"issues": [
  {"file": "app/a.ts", "owners": [{"name": "team"}], "dependencies": [{"name": "foo"}],
   "exports": [{"name": "a"}, {"name": "b"}], "types": []},
  {"file": "app/b.ts", "owners": [], "unlisted": [{"name": "zed"}], "files": []}
]}
EOF
  export STUB_KNIP_PAYLOAD="$BATS_TEST_TMPDIR/knip.json"
  export STUB_ADVISORIES_PAYLOAD="$BATS_TEST_TMPDIR/advisories.json"
  export STUB_REACT_DOCTOR_OUTPUT="$SAMPLE"
}

# branch_with <path>...: a feature branch off main that adds each path.
branch_with() {
  git -C "$SANDBOX" checkout -q -b feature
  local added
  for added in "$@"; do
    mkdir -p "$SANDBOX/$(dirname "$added")"
    printf 'content\n' >"$SANDBOX/$added"
    git -C "$SANDBOX" add "$added"
  done
  git -C "$SANDBOX" commit -q -m change
}

run_oracles() {
  run --separate-stderr bash "$SCRIPT" --root "$SANDBOX" --base "$1" --out "$OUT_DIR"
}

row() {
  printf '%s\n' "$output" | grep "^| $1 |"
}

invoked() {
  grep -c "^$1 start" "$STUB_LOG" || true
}

@test "a markdown-only change skips both gated oracles and still runs advisories" {
  branch_with docs/note.md
  run_oracles "$BASE_SHA"
  [ "$status" -eq 0 ]
  [ "$(invoked npx)" -eq 0 ]
  [ "$(invoked pnpm)" -eq 0 ]
  [ "$(invoked gaia)" -eq 1 ]
  [ "$(printf '%s\n' "$output" | sed -n 1p)" = '| Oracle | Status | Result | Output |' ]
  [ "$(printf '%s\n' "$output" | sed -n 2p)" = '|---|---|---|---|' ]
  row react-doctor | grep -q 'skipped: no .ts or .tsx path in scope'
  row knip | grep -q 'skipped: no .ts, .tsx, manifest or lockfile path in scope'
  row advisories | grep -q 'ran (exit 0)'
}

@test "a package.json-only change runs knip and not react-doctor" {
  branch_with package.json
  run_oracles "$BASE_SHA"
  [ "$status" -eq 0 ]
  [ "$(invoked npx)" -eq 0 ]
  [ "$(invoked pnpm)" -eq 1 ]
  row react-doctor | grep -q 'skipped'
  row knip | grep -q 'ran (exit 0)'
}

@test "a pnpm-lock.yaml-only change runs knip" {
  branch_with pnpm-lock.yaml
  run_oracles "$BASE_SHA"
  [ "$status" -eq 0 ]
  [ "$(invoked pnpm)" -eq 1 ]
  [ "$(invoked npx)" -eq 0 ]
}

@test "a nested package.json and a pnpm-workspace.yaml each run knip" {
  branch_with frontend/package.json
  run_oracles "$BASE_SHA"
  [ "$(invoked pnpm)" -eq 1 ]
  git -C "$SANDBOX" checkout -q main
  git -C "$SANDBOX" branch -q -D feature
  : >"$STUB_LOG"
  branch_with pnpm-workspace.yaml
  run_oracles "$BASE_SHA"
  [ "$(invoked pnpm)" -eq 1 ]
}

@test "a tsx change runs all three oracles" {
  branch_with app/page.tsx
  run_oracles "$BASE_SHA"
  [ "$status" -eq 0 ]
  [ "$(invoked npx)" -eq 1 ]
  [ "$(invoked pnpm)" -eq 1 ]
  [ "$(invoked gaia)" -eq 1 ]
  row react-doctor | grep -q 'ran (exit 0)'
  row knip | grep -q 'ran (exit 0)'
}

@test "the oracles run concurrently: all started before any ended" {
  branch_with app/page.ts
  export STUB_SLEEP=1
  run_oracles "$BASE_SHA"
  [ "$status" -eq 0 ]
  [ "$(awk '{print $2}' "$STUB_LOG" | paste -sd' ' -)" = "start start start end end end" ]
}

@test "an unresolvable base runs everything and says the scope was unresolved" {
  branch_with docs/note.md
  run_oracles 0000000000000000000000000000000000000001
  [ "$status" -eq 0 ]
  [ "$(invoked npx)" -eq 1 ]
  [ "$(invoked pnpm)" -eq 1 ]
  [ "$(invoked gaia)" -eq 1 ]
  row react-doctor | grep -q 'scope unresolved; ran anyway'
  row knip | grep -q 'scope unresolved; ran anyway'
}

@test "the same markdown-only branch with a valid base skips both (red twin)" {
  branch_with docs/note.md
  run_oracles "$BASE_SHA"
  [ "$(invoked npx)" -eq 0 ]
  [ "$(invoked pnpm)" -eq 0 ]
  row react-doctor | grep -q 'scope unresolved' && return 1
  true
}

@test "an empty --base followed by --out runs everything, writes to --out and exits 0" {
  branch_with docs/note.md
  run --separate-stderr bash "$SCRIPT" --root "$SANDBOX" --base '' --out "$OUT_DIR"
  [ "$status" -eq 0 ]
  [ "$(invoked npx)" -eq 1 ]
  [ "$(invoked pnpm)" -eq 1 ]
  [ "$(invoked gaia)" -eq 1 ]
  [ -f "$OUT_DIR/react-doctor.txt" ]
  [ -f "$OUT_DIR/knip.json" ]
  [ -f "$OUT_DIR/advisories.json" ]
  row react-doctor | grep -q 'scope unresolved; ran anyway'
}

@test "a parser that skips an empty --base value exits 2 on the same call (red twin)" {
  branch_with docs/note.md
  local mutant="$SANDBOX/.gaia/scripts/mutant.sh"
  perl -pe 's/^(\s*)base=\$2$/$1if [ -z "\$2" ]; then shift; continue; fi\n$1base=\$2/' "$SCRIPT" >"$mutant"
  cmp -s "$SCRIPT" "$mutant" && return 1
  run --separate-stderr bash "$mutant" --root "$SANDBOX" --base '' --out "$OUT_DIR"
  [ "$status" -eq 2 ]
}

@test "advisories: one surfaced high, one acknowledged critical, a single second-table row" {
  branch_with docs/note.md
  run_oracles "$BASE_SHA"
  row advisories | grep -q '1 high/critical surfaced; 1 acknowledged suppressed'
  printf '%s\n' "$output" | grep -qx '| Package | Severity | Advisory | Fix |'
  [ "$(printf '%s\n' "$output" | grep -c '^| lodash |')" -eq 1 ]
  printf '%s\n' "$output" | grep -qx '| lodash | high | GHSA-aaaa-bbbb-cccc | 4.17.21 |'
  printf '%s\n' "$output" | grep -q 'minimist' && return 1
  printf '%s\n' "$output" | grep -q 'left-pad' && return 1
  true
}

@test "advisories: an unpatched surfaced row falls back to the override hint" {
  branch_with docs/note.md
  printf '%s' '{"source":"dependabot","advisories":[{"package":"p","severity":"critical","ghsa":null,"key":"pnpm:9","firstPatchedVersion":null,"patchedVersions":[],"baselineAcknowledged":false}]}' >"$BATS_TEST_TMPDIR/unpatched.json"
  export STUB_ADVISORIES_PAYLOAD="$BATS_TEST_TMPDIR/unpatched.json"
  run_oracles "$BASE_SHA"
  printf '%s\n' "$output" | grep -qx '| p | critical | pnpm:9 | no patched range; consider an override or a baseline acknowledgment |'
}

@test "advisories: an unavailable source reads source unavailable and no second table" {
  branch_with docs/note.md
  printf '%s' '{"source":"unavailable","advisories":[]}' >"$BATS_TEST_TMPDIR/unavailable.json"
  export STUB_ADVISORIES_PAYLOAD="$BATS_TEST_TMPDIR/unavailable.json"
  run_oracles "$BASE_SHA"
  row advisories | grep -q 'source unavailable'
  printf '%s\n' "$output" | grep -q 'Package | Severity' && return 1
  true
}

@test "advisories: an empty list reads No high/critical advisories and no second table" {
  branch_with docs/note.md
  printf '%s' '{"source":"dependabot","advisories":[]}' >"$BATS_TEST_TMPDIR/empty.json"
  export STUB_ADVISORIES_PAYLOAD="$BATS_TEST_TMPDIR/empty.json"
  run_oracles "$BASE_SHA"
  row advisories | grep -q 'No high/critical advisories'
  printf '%s\n' "$output" | grep -q 'Package | Severity' && return 1
  true
}

@test "knip: rows holding only empty arrays read No issues" {
  branch_with app/page.ts
  printf '%s' '{"issues":[{"file":"a.ts","owners":[],"exports":[],"files":[]},{"file":"b.ts","types":[]}]}' >"$BATS_TEST_TMPDIR/knip-clean.json"
  export STUB_KNIP_PAYLOAD="$BATS_TEST_TMPDIR/knip-clean.json"
  run_oracles "$BASE_SHA"
  row knip | grep -q '| No issues |'
}

@test "knip: the canned payload yields per-type counts in descending count then key order" {
  branch_with app/page.ts
  run_oracles "$BASE_SHA"
  row knip | grep -q '| 4 issues: exports=2, dependencies=1, unlisted=1 |'
}

@test "knip: a row holding only a cycles entry counts, and owners never do" {
  branch_with app/page.ts
  printf '%s' '{"issues":[{"file":"a.ts","owners":[{"name":"team"}],"cycles":[["a.ts","b.ts"]]}]}' >"$BATS_TEST_TMPDIR/knip-cycles.json"
  export STUB_KNIP_PAYLOAD="$BATS_TEST_TMPDIR/knip-cycles.json"
  run_oracles "$BASE_SHA"
  row knip | grep -q '| 1 issues: cycles=1 |'
  row knip | grep -q 'owners' && return 1
  true
}

@test "knip: a non-zero exit with a parseable payload is still ran" {
  branch_with app/page.ts
  export STUB_KNIP_RC=1
  run_oracles "$BASE_SHA"
  [ "$status" -eq 0 ]
  row knip | grep -q 'ran (exit 1)'
}

@test "react-doctor: the recorded sample yields the count the pinned rule gives" {
  branch_with app/page.tsx
  run_oracles "$BASE_SHA"
  row react-doctor | grep -q '| 6 diagnostics |'
}

@test "react-doctor: empty output reads No issues" {
  branch_with app/page.tsx
  unset STUB_REACT_DOCTOR_OUTPUT
  run_oracles "$BASE_SHA"
  row react-doctor | grep -q '| No issues |'
}

@test "a stub failing with no parseable output is a failed row while the others stand" {
  branch_with app/page.tsx
  unset STUB_KNIP_PAYLOAD
  export STUB_KNIP_RC=3
  run_oracles "$BASE_SHA"
  [ "$status" -eq 0 ]
  row knip | grep -q 'failed (exit 3)'
  row react-doctor | grep -q 'ran (exit 0)'
  row advisories | grep -q 'ran (exit 0)'
}

@test "usage errors exit 2: missing --root, missing --out, unknown flag" {
  run --separate-stderr bash "$SCRIPT" --base "$BASE_SHA" --out "$OUT_DIR"
  [ "$status" -eq 2 ]
  run --separate-stderr bash "$SCRIPT" --root "$SANDBOX" --base "$BASE_SHA"
  [ "$status" -eq 2 ]
  [ "${stderr#*usage}" != "$stderr" ]
  run --separate-stderr bash "$SCRIPT" --root "$SANDBOX" --out "$OUT_DIR" --bogus
  [ "$status" -eq 2 ]
}

@test "stdout is the table and nothing else" {
  branch_with app/page.tsx
  run_oracles "$BASE_SHA"
  [ -z "$(printf '%s\n' "$output" | grep -v '^|' | grep -v '^$')" ]
}
