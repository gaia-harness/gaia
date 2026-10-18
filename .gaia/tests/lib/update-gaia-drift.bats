#!/usr/bin/env bats
# update-gaia-drift.sh: the undecided setup features a release lists, split into
# the tokens the update flow acts on. Runs against a fixture project with a
# stub `.gaia/cli/gaia`.
#
# Assertion style per .claude/rules/bats-assertions.md.
#
# Maintainer-only. `.gaia/tests` is wholesale release-excluded.

setup() {
  REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/../../.." && pwd)"
  SCRIPT="$REPO_ROOT/.gaia/scripts/update-gaia-drift.sh"
}

# A fixture project with a stub CLI. $DRIFT_JSON is what `setup drift` prints;
# $ADMIN_ANSWER is check-admin's `admin` value; $DRIFT_FAILS makes drift fail.
make_drift_fixture() {
  PROJECT="$BATS_TEST_TMPDIR/drift"
  rm -rf "$PROJECT"
  mkdir -p "$PROJECT/.gaia/cli"
  cat > "$PROJECT/.gaia/cli/gaia" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  'setup drift')
    [ -z "$DRIFT_FAILS" ] || { echo 'features list unreadable' >&2; exit 1; }
    printf '%s\n' "$DRIFT_JSON"
    ;;
  'setup detect-remote')
    printf '%s\n' '{"found":true,"host":"github.com","owner":"acme","repo":"app"}'
    ;;
  'setup check-admin')
    printf '{"admin":%s,"auth_status":"ok"}\n' "$ADMIN_ANSWER"
    ;;
  *) exit 2 ;;
esac
STUB
  chmod +x "$PROJECT/.gaia/cli/gaia"
}

# Runs the script from the fixture project. Arguments are NAME=value pairs
# exported into its environment.
run_drift() {
  # shellcheck disable=SC2016  # the inner script expands its own positional arguments
  run env "$@" bash -c 'cd "$1" || exit 99; exec bash "$2" --features bundle/.gaia/setup-features.json' _ "$PROJECT" "$SCRIPT"
}

DRIFT_FIXTURE='{"features":"x","recorded":{"project":1,"machine":1},"decided":{},"undecided":[
{"id":"A","scope":"project","required":true,"admin":false,"standalone":true,"reference":"ref/a.md","action":"apply"},
{"id":"B","scope":"machine","required":false,"admin":false,"standalone":true,"reference":"ref/b.md","action":"ask"},
{"id":"C","scope":"project","required":true,"admin":true,"standalone":true,"reference":"ref/c.md","action":"apply"},
{"id":"D","scope":"machine","required":true,"admin":false,"standalone":true,"reference":"ref/d.md","action":"apply"},
{"id":"W","scope":"project","required":true,"admin":true,"standalone":false,"reference":"ref/w.md","action":"setup"}]}'

@test "drift splits undecided features into apply, ask, owed-by-admin and setup" {
  make_drift_fixture
  run_drift DRIFT_JSON="$DRIFT_FIXTURE" ADMIN_ANSWER=false
  [ "$status" -eq 0 ]
  expected="$(printf '%s\n' 'APPLY A ref/a.md' 'ASK B ref/b.md' 'OWED_ADMIN C' 'APPLY D ref/d.md' 'SETUP W')"
  [ "$output" = "$expected" ]
}

@test "an admin applies the admin-gated feature" {
  make_drift_fixture
  run_drift DRIFT_JSON="$DRIFT_FIXTURE" ADMIN_ANSWER=true
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qxF 'APPLY C ref/c.md'
  printf '%s\n' "$output" | grep -qF OWED_ADMIN && return 1
  true
}

@test "a failing drift prints DRIFT_FAILED and exits 0" {
  make_drift_fixture
  run_drift DRIFT_JSON='' ADMIN_ANSWER=false DRIFT_FAILS=1
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qxF 'DRIFT_FAILED features list unreadable'
}

@test "unreadable drift output prints DRIFT_FAILED and exits 0" {
  make_drift_fixture
  run_drift DRIFT_JSON='not json' ADMIN_ANSWER=false
  [ "$status" -eq 0 ]
  [ "$output" = 'DRIFT_FAILED drift output unreadable' ]
}

@test "usage errors exit 2" {
  run bash "$SCRIPT"
  [ "$status" -eq 2 ]
  run bash "$SCRIPT" --features
  [ "$status" -eq 2 ]
  run bash "$SCRIPT" --bogus x
  [ "$status" -eq 2 ]
}
