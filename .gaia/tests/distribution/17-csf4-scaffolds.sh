#!/usr/bin/env bash
# 17-csf4-scaffolds.sh
# distribution-runner: exclusive
# distribution-runner: paths .gaia/cli/src/init/** .gaia/cli/src/scaffold/** .gaia/cli/templates/** pnpm-lock.yaml
# distribution-runner: paths frontend/package.json frontend/.storybook/** frontend/eslint.config.mjs frontend/tsconfig.json frontend/vite.config.ts frontend/vitest.config.ts frontend/react-router.config.ts frontend/app/root.tsx frontend/app/state/** frontend/app/services/** frontend/test/**
#
# Adopter-flow regression for the scaffolds and the init commands that edit
# the CSF Next preview, in four staged release trees:
#
#   data-layer-off / branding-kept      no init command beyond the scaffolds
#   data-layer-off / branding-stripped  `gaia init strip-branding`
#   data-layer-on  / branding-kept      `gaia init configure-data-layer --query true`
#   data-layer-on  / branding-stripped  both
#
# In each tree: a component, a route and a data route (a service plus a route
# bound to it) are scaffolded. Every generated story file imports the preview
# through `#.storybook/preview`, holds a `.test(` call, and has no `expect(`
# inside any `play`; the data route's story installs its handlers in a
# `beforeEach` and uses no `parameters.msw`. Then typecheck, lint (no fix) over
# the generated files, and the Storybook Vitest project over them pass, with
# every generated story file in the report holding at least one test, all
# passing. The preview typechecks after the init edits (the typecheck covers
# `.storybook/`).
#
# The first tree also proves the play check can fail: a copy of a generated
# story with an `expect(` added inside its play is rejected.
#
# Layer 0: needs host pnpm and network access for the install and Chromium.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib/lib.sh"
source "$HERE/lib/data-layer.sh"

require_command pnpm "pnpm required for the CSF4 scaffold scenario (Layer 0)"
require_command rsync "rsync required for adopter-flow scaffold copy"
require_command node "node required to read the CLI's JSON output"

SECONDS=0
SCAFFOLD_CHECK="$HERE/lib/csf4-scaffold-check.mjs"
STAGING="$(mktemp -d -t gaia-dist-csf4-scaffolds-stage-XXXXXX)"
WORK="$(mktemp -d -t gaia-dist-csf4-scaffolds-work-XXXXXX)"
TREES=()
cleanup() {
  rm -rf "$STAGING" "$WORK"
  rm -rf ${TREES[@]+"${TREES[@]}"}
}
trap cleanup EXIT
capture_cli_stderr "$WORK/cli-stderr.txt"
export GAIA_TELEMETRY_PING_DISABLE=1

"$HERE/lib/build-staging.sh" "$STAGING" > "$WORK/build-staging.log" 2>&1 \
  || { tail -n 40 "$WORK/build-staging.log" >&2; fail "build-staging failed"; exit 1; }

# Runs one scaffold or init command in the current tree, output discarded.
tree_gaia() {
  local label="$1"
  shift
  (cd "$SCAFFOLD" && run_cli "$GAIA" "$@") > /dev/null \
    || fail_with_stderr "gaia $* exited non-zero (step: $label)"
}

# check_stories KIND FILE...  - FILEs are frontend-relative
check_stories() {
  local kind="$1" problems
  shift
  problems="$(node "$SCAFFOLD_CHECK" "$FRONTEND" "$kind" "$@")" \
    || { printf '%s\n' "$problems" >&2; fail "$TREE_LABEL: generated $kind story fails the CSF4 shape check"; exit 1; }
}

# Every generated story must be in the report with at least one test, all passing.
assert_stories_all_pass() {
  local report="$1" story outcome
  shift
  for story in "$@"; do
    # shellcheck disable=SC2016 # the template literal is JavaScript, not shell
    outcome="$(node -e '
      const report = JSON.parse(require("node:fs").readFileSync(process.argv[1], "utf8"));
      const match = report.testResults.find((result) => result.name.endsWith(process.argv[2]));
      const tests = match ? match.assertionResults : [];
      const failed = tests.filter((test) => test.status !== "passed");
      process.stdout.write(tests.length > 0 && failed.length === 0 ? "ok" : `${tests.length} tests, ${failed.length} not passing`);
    ' "$report" "$story")"
    [ "$outcome" = "ok" ] \
      || { fail "$TREE_LABEL: $story: $outcome in the Storybook Vitest report"; exit 1; }
  done
}

# Proves the play check can fail: an expect( added inside a play must be rejected.
prove_play_check_fails() {
  local source_story="$1" probe="app/play-probe.stories.tsx" problems
  awk '
    /^export const [A-Za-z]+ = meta\.story\(\{$/ && !done {
      print; print "  play: async () => {"; print "    await expect(1).toBe(1);"; print "  },"; done = 1; next
    }
    { print }
  ' "$FRONTEND/$source_story" > "$FRONTEND/$probe"
  grep -q 'await expect(1)' "$FRONTEND/$probe" \
    || { rm -f "$FRONTEND/$probe"; fail "play probe: no story to inject an expect into in $source_story"; exit 1; }
  if problems="$(node "$SCAFFOLD_CHECK" "$FRONTEND" plain "$probe")"; then
    rm -f "$FRONTEND/$probe"
    fail "the play check passed a story with an expect( inside its play"
    exit 1
  fi
  rm -f "$FRONTEND/$probe"
  grep -q 'expect( sits inside a play' <<<"$problems" \
    || { fail "the play check failed for another reason: $problems"; exit 1; }
}

# run_tree DATA_LAYER BRANDING
run_tree() {
  local data_layer="$1" branding="$2" proved_check="${3:-}"
  local data_flag component_story route_story data_story
  TREE_LABEL="data-layer-$data_layer/branding-$branding"
  log "tree: $TREE_LABEL"

  SCAFFOLD="$(mktemp -d -t "gaia-dist-csf4-scaffolds-$data_layer-$branding-XXXXXX")"
  TREES+=("$SCAFFOLD")
  rsync -a "$STAGING"/ "$SCAFFOLD"/
  git -C "$SCAFFOLD" init -q
  GAIA="$SCAFFOLD/.gaia/cli/gaia"
  FRONTEND="$SCAFFOLD/frontend"

  if [ "$data_layer" = "on" ]; then
    tree_gaia "configure-data-layer" init configure-data-layer --casing snake --query true
    data_flag=query
  else
    data_flag=client
  fi
  if [ "$branding" = "stripped" ]; then
    tree_gaia "strip-branding" init strip-branding --title "Test Project"
  fi

  if [ "$data_layer" = "on" ]; then
    run_logged "$TREE_LABEL: pnpm install" "$WORK/$data_layer-$branding-install.log" \
      pnpm -C "$SCAFFOLD" install --no-frozen-lockfile
  else
    run_logged "$TREE_LABEL: pnpm install" "$WORK/$data_layer-$branding-install.log" \
      pnpm -C "$SCAFFOLD" install --frozen-lockfile
  fi
  run_logged "$TREE_LABEL: playwright install chromium" "$WORK/chromium.log" install_chromium "$SCAFFOLD"

  tree_gaia "scaffold component" scaffold component probe-widget
  tree_gaia "scaffold route" scaffold route about --group _public
  tree_gaia "scaffold service" scaffold service items \
    --endpoints get,post,put,delete --schema "id:string,displayName:string" --mocks
  tree_gaia "scaffold data route" scaffold route items --group _public \
    --data "$data_flag" --service items --shape list --action --i18n

  component_story="app/components/probe-widget/tests/index.stories.tsx"
  route_story="app/pages/about/tests/page.stories.tsx"
  data_story="app/pages/items/tests/page.stories.tsx"
  for story in "$component_story" "$route_story" "$data_story"; do
    [ -f "$FRONTEND/$story" ] || { fail "$TREE_LABEL: scaffold wrote no $story"; exit 1; }
  done

  check_stories plain "$component_story" "$route_story"
  check_stories data "$data_story"
  if [ -n "$proved_check" ]; then
    prove_play_check_fails "$component_story"
  fi

  # typecheck covers .storybook/, so it also proves the init-edited preview.
  run_pnpm_steps "$data_layer-$branding-" "$TREE_LABEL" typecheck
  log "eslint over the generated files (no fix)"
  run_logged "$TREE_LABEL: eslint" "$WORK/$data_layer-$branding-eslint.log" \
    pnpm -C "$FRONTEND" exec eslint --max-warnings=0 --no-cache \
      "$component_story" "$route_story" "$data_story" "${component_story%/tests/*}/index.tsx"
  log "Storybook Vitest project over the generated files"
  pnpm -C "$FRONTEND" exec vitest run --project storybook \
    --reporter=json --outputFile="$WORK/$data_layer-$branding-report.json" \
    "$component_story" "$route_story" "$data_story" \
    < /dev/null > "$WORK/$data_layer-$branding-vitest.log" 2>&1 \
    || { tail -n 60 "$WORK/$data_layer-$branding-vitest.log" >&2; fail "$TREE_LABEL: the Storybook Vitest project failed"; exit 1; }
  assert_stories_all_pass "$WORK/$data_layer-$branding-report.json" \
    "$component_story" "$route_story" "$data_story"
  rm -rf "$SCAFFOLD"
}

run_tree off kept proved
run_tree off stripped
run_tree on kept
run_tree on stripped

pass "scaffolded component, route and data route stories are CSF4 with tests and no expect in a play, in all four data-layer and branding trees (${SECONDS}s)"
