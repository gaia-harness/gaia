#!/usr/bin/env bash
# 19-crossing-edits.sh
#
# The crossing's edits and the notes that reach it, proven against the staged
# bundle (the shipped file set, with the adopter binary an adopter runs).
#
#   1. The committed copies of each older release's `select_notes` run against
#      the staged bundle for a 2.0.0, 2.3.0 and 2.3.1 baseline and a 2.4.0
#      target: each emits the blocking note, and 2.0.0 lists the 2.3.0
#      after-merge note ahead of it. The crossing note passes the release scrub.
#   2. On a monorepo fixture carried across by the real verbs: the app's
#      workspace entry becomes apps/*, every other entry keeps its order,
#      packages/* appears once, an unlisted apps/legacy is reported by name,
#      the list equals the expected list and the rest of the file is
#      byte-identical. The registry points web at apps/web and keeps every
#      other member; the opted-in API app generates settings and the drift
#      check exits 0.
#   3. The same edits on a stock tree: apps/web, the list apps/* and
#      packages/*, and an explicit registry naming web.
#
# Layer 0.5: runs on the host or runner, no Docker, no pnpm install.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib/lib.sh"
source "$HERE/lib/data-layer.sh"
source "$HERE/lib/crossed-fixture.sh"

require_command jq "jq is required to read the registry"
require_command rsync "rsync required for adopter-flow scaffold copy"

stage_adopter_tree crossing-edits
OLD_SELECTORS="$PROJECT_ROOT/.gaia/tests/fixtures/crossing/old-selector"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com

# --- 1. Older selectors against the staged bundle ----------------------------

NOTE="$STAGING/.gaia/migrations/2.4.0.md"
[ -f "$NOTE" ] || { fail "the staged bundle ships no 2.4.0 migration note"; exit 1; }

# select_from TAG BASELINE TARGET: the tag's select_notes over $BUNDLE, with the
# variables its flag parse would set.
select_from() {
  bash -c '. "$1"; latest_dir="$2"; baseline="$3"; latest="$4"; select_notes' \
    _ "$OLD_SELECTORS/select-notes-$1.sh" "$BUNDLE" "$2" "$3"
}

# The bundle carries the staged notes with each selector in turn: the committed
# copy of the older one and the staged one.
for selector in "$OLD_SELECTORS/select-migration-notes.sh" "$STAGING/.gaia/scripts/select-migration-notes.sh"; do
  BUNDLE="$WORK/selector-bundle"
  rm -rf "$BUNDLE"
  mkdir -p "$BUNDLE/.gaia/scripts/lib" "$BUNDLE/.gaia/migrations"
  cp "$STAGING"/.gaia/migrations/*.md "$BUNDLE/.gaia/migrations/"
  cp "$selector" "$BUNDLE/.gaia/scripts/select-migration-notes.sh"
  cp "$STAGING/.gaia/scripts/lib/version-compare.awk" "$BUNDLE/.gaia/scripts/lib/"
  expected="$(printf 'AFTER_MERGE 2.3.0 %s\nBLOCKING 2.4.0 %s' "$BUNDLE/.gaia/migrations/2.3.0.md" "$BUNDLE/.gaia/migrations/2.4.0.md")"
  [ "$(select_from v2.0.0 2.0.0 2.4.0)" = "$expected" ] \
    || { fail "the v2.0.0 selector did not list the 2.3.0 note ahead of the blocking note"; exit 1; }
  for tag in v2.3.0 v2.3.1; do
    [ "$(select_from "$tag" "${tag#v}" 2.4.0)" = "BLOCKING 2.4.0 $BUNDLE/.gaia/migrations/2.4.0.md" ] \
      || { fail "the $tag selector did not stop at the blocking note"; exit 1; }
  done
done

SCRUB_TREE="$WORK/scrub-note"
mkdir -p "$SCRUB_TREE/.gaia/migrations"
cp "$NOTE" "$SCRUB_TREE/.gaia/migrations/2.4.0.md"
"$PROJECT_ROOT/.gaia/cli/gaia-maintainer" release scrub "$SCRUB_TREE" --config "$PROJECT_ROOT/.gaia/release-scrub.yml" \
  >"$WORK/scrub.log" 2>&1 \
  || { tail -n 20 "$WORK/scrub.log" >&2; fail "the staged crossing note fails the release scrub"; exit 1; }

# --- 2. Monorepo fixture -----------------------------------------------------

export CROSSED_FIXTURE_GAIA="$GAIA"
export CROSSED_FIXTURE_UNLISTED_APP=legacy
FIXTURE="$WORK/monorepo"
LOG_DIR="$WORK/verb-logs"
mkdir -p "$LOG_DIR"
CROSSED_FIXTURE_LOG_DIR="$LOG_DIR" crossed_fixture_build "$FIXTURE" \
  || { fail "the crossed fixture could not be built from the staged binary"; exit 1; }
unset CROSSED_FIXTURE_UNLISTED_APP

# list_of FILE: the packages list, one entry per line, in file order.
list_of() {
  awk '/^packages:/ { in_list = 1; next } in_list && /^  - / { sub(/^  - /, ""); print; next } in_list { exit }' "$1"
}

SEED_COMMIT="$(git -C "$FIXTURE" rev-list --max-parents=0 HEAD)"
git -C "$FIXTURE" show "$SEED_COMMIT:pnpm-workspace.yaml" >"$WORK/monorepo-before.yaml"
EXPECTED_LIST='apps/*
apps/mobile
apps/api
packages/kit
packages/shared
packages/tokens
infra
.gaia/cli
packages/*'
[ "$(list_of "$FIXTURE/pnpm-workspace.yaml")" = "$EXPECTED_LIST" ] \
  || { fail "the monorepo workspace list is not the expected list: $(list_of "$FIXTURE/pnpm-workspace.yaml" | tr '\n' ' ')"; exit 1; }
MONOREPO_LIST="$(list_of "$FIXTURE/pnpm-workspace.yaml")"
[ "$(grep -cxF 'packages/*' <<<"$MONOREPO_LIST")" -eq 1 ] \
  || { fail "packages/* does not appear exactly once"; exit 1; }
printf 'packages:\n  - apps/*\n  - apps/mobile\n  - apps/api\n  - packages/kit\n  - packages/shared\n  - packages/tokens\n  - infra\n  - .gaia/cli\n  - packages/*\n' >"$WORK/monorepo-expected.yaml"
cmp -s "$WORK/monorepo-expected.yaml" "$FIXTURE/pnpm-workspace.yaml" \
  || { fail "the monorepo workspace file differs from the expected text"; exit 1; }
grep -qxF "$(printf 'REPORT\tnewly-matched\tapps/legacy')" "$LOG_DIR/move.log" \
  || { fail "the move did not report the unlisted apps/legacy by name: $(cat "$LOG_DIR/move.log")"; exit 1; }

git -C "$FIXTURE" show "$SEED_COMMIT:.gaia/packages.json" >"$WORK/monorepo-registry-before.json"
[ "$(jq -r '.[] | select(.name == "web") | .path' "$FIXTURE/.gaia/packages.json")" = apps/web ] \
  || { fail "the registry does not point web at apps/web"; exit 1; }
[ "$(jq -c '[.[] | select(.name != "web")]' "$FIXTURE/.gaia/packages.json")" = "$(jq -c '[.[] | select(.name != "frontend")]' "$WORK/monorepo-registry-before.json")" ] \
  || { fail "the registry changed a member other than web"; exit 1; }
[ "$(jq -r '.generatedSettings' "$FIXTURE/apps/api/gaia.package.json")" = true ] \
  || { fail "apps/api does not generate settings after the crossing"; exit 1; }

mkdir -p "$FIXTURE/.claude/hooks/lib" "$FIXTURE/.gaia/scripts" "$FIXTURE/.gaia/cli"
cp "$STAGING/.claude/settings.json" "$FIXTURE/.claude/settings.json"
cp "$STAGING/.claude/hooks/lib/gaia-packages.sh" "$FIXTURE/.claude/hooks/lib/gaia-packages.sh"
cp "$STAGING/.gaia/scripts/check-settings-drift.sh" "$FIXTURE/.gaia/scripts/check-settings-drift.sh"
cp "$GAIA" "$FIXTURE/.gaia/cli/gaia"
(cd "$FIXTURE" && run_cli ./.gaia/cli/gaia packages sync-settings) >/dev/null \
  || fail_with_stderr "packages sync-settings failed on the crossed fixture"
bash "$FIXTURE/.gaia/scripts/check-settings-drift.sh" "$FIXTURE" >/dev/null 2>&1 \
  || { fail "the settings drift check fails on the crossed fixture"; exit 1; }
log "monorepo fixture: workspace list, report, registry and settings OK"

# --- 3. Stock tree -----------------------------------------------------------

STOCK="$WORK/stock"
mkdir -p "$STOCK/frontend/app" "$STOCK/.gaia"
_crossed_fixture_git_init "$STOCK"
printf '{\n  "name": "frontend",\n  "private": true\n}\n' >"$STOCK/frontend/package.json"
printf 'export const index = 1;\n' >"$STOCK/frontend/app/index.ts"
_crossed_fixture_descriptor "$STOCK/frontend/gaia.package.json" frontend
printf '# Project\n' >"$STOCK/CLAUDE.md"
printf '{\n  "name": "project",\n  "private": true\n}\n' >"$STOCK/package.json"
printf '.gaia/local\n.notebook\nnode_modules\n' >"$STOCK/.gitignore"
printf '[{"name":"frontend","path":"frontend"}]\n' >"$STOCK/.gaia/packages.json"
STOCK_TAIL='
# pnpm settings.
minimumReleaseAge: 4320
'
printf 'packages:\n  - frontend\n%s' "$STOCK_TAIL" >"$STOCK/pnpm-workspace.yaml"
printf 'auditors:\n  - name: code-audit-frontend\n    globs:\n      - "frontend/app/**"\n      - "package.json"\n    audience: adopter\n    default: true\nunowned:\n  - "*.md"\n' \
  >"$STOCK/.gaia/audit-ci.yml"
jq -n '{files: {"frontend/app/index.ts": "owned", ".gaia/VERSION": "owned"}, version: "2.3.1"}' >"$STOCK/.gaia/manifest.json"
printf '2.3.1\n' >"$STOCK/.gaia/VERSION"
_crossed_fixture_commit "$STOCK" seed
for verb in preflight move roster; do
  (cd "$STOCK" && run_cli "$GAIA" update crossing "$verb") >"$WORK/stock-$verb.log" \
    || fail_with_stderr "crossing $verb failed on the stock tree"
  _crossed_fixture_commit "$STOCK" "$verb"
done

[ -f "$STOCK/apps/web/package.json" ] && [ ! -e "$STOCK/frontend" ] \
  || { fail "the stock tree does not end with the app at apps/web"; exit 1; }
printf 'packages:\n  - apps/*\n  - packages/*\n%s' "$STOCK_TAIL" >"$WORK/stock-expected.yaml"
cmp -s "$WORK/stock-expected.yaml" "$STOCK/pnpm-workspace.yaml" \
  || { fail "the stock workspace file is not apps/* and packages/* with the rest byte-identical"; exit 1; }
[ "$(jq -c '.' "$STOCK/.gaia/packages.json")" = '[{"name":"web","path":"apps/web"}]' ] \
  || { fail "the stock registry does not name web at apps/web: $(cat "$STOCK/.gaia/packages.json")"; exit 1; }
[ "$(jq -r '.name' "$STOCK/apps/web/package.json")" = web ] \
  || { fail "the stock app package is not named web"; exit 1; }

pass "crossing edits: older selectors reach the blocking note, workspace list and registry edits hold on a monorepo and a stock tree"
