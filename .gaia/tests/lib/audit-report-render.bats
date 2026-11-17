#!/usr/bin/env bats
# Flow test: a SPEC audit cache plus the routing record a fold writes render an
# AUDIT.md that requirement-keys.sh reads. Happy path only; section placement,
# ordering and refusals belong to audit-render.bats. The fixture is a podcast
# catalogue, built in $BATS_TEST_TMPDIR.
#
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  CACHE="$BATS_TEST_TMPDIR/cache"
  mkdir -p "$CACHE/findings" "$CACHE/verdicts"
}

@test "the fold routing record renders an AUDIT.md the requirement keys read" {
  CACHE="$CACHE" ROUTING="$BATS_TEST_TMPDIR/routing.json" node --input-type=module - <<'NODE'
import {writeFileSync} from 'node:fs';
const cache = process.env.CACHE;
const write = (path, value) => writeFileSync(`${cache}/${path}`, JSON.stringify(value));
const finding = (id, title, extra = {}) => ({
  id, severity: 'major', title, location: 'catalogue.md:1', issue: `${title} issue`,
  evidence: 'episodes.ts:10', recommendation: `${title} fix`, ...extra,
});
write('findings/catalogue.json', {dimension: 'catalogue', brief_token: 'a'.repeat(32), findings: [
  finding('CAT-001', 'Duplicate episode', {proposed_disposition: 'plan_directive', directive: 'Adding an episode with an existing guid is refused and changes nothing'}),
  finding('CAT-002', 'Unbounded feed', {proposed_disposition: 'plan_directive'}),
]});
write('verdicts/CAT-001.json', {verdict: 'confirmed', corrected_severity: 'major', disposition: 'plan_directive', reasoning: 'Confirmed.', evidence: 'episodes.ts:10'});
write('verdicts/CAT-002.json', {verdict: 'partial', corrected_severity: 'minor', disposition: 'plan_directive', reasoning: 'Only the public feed is unbounded.', evidence: 'feed.ts:4'});
const survivor = (id, verdict, severity, directiveText) => ({
  id, status: 'survived', corrected_severity: severity, verdict, disposition: 'plan_directive',
  decision: null, folded_text: null, directive_text: directiveText,
});
writeFileSync(process.env.ROUTING, JSON.stringify({
  tier: 'standard',
  verdict: 'Plannable as written.',
  findings: [
    survivor('CAT-001', 'confirmed', 'major', null),
    survivor('CAT-002', 'partial', 'minor', 'The public feed returns at most 50 episodes per page'),
  ],
}));
const records = [
  {phase: 'lens', lens: 'catalogue', disposition: 'first_pass'},
  {phase: 'refuter', lens: 'catalogue', disposition: 'first_pass'},
];
writeFileSync(`${cache}/coverage.jsonl`, `${records.map((record) => JSON.stringify(record)).join('\n')}\n`);
NODE

  # The flow reader requires a prefixed flow id; it is assembled here so the
  # file holds no working-document id literal.
  flow_prefix='FLOW'
  cat >"$BATS_TEST_TMPDIR/SPEC.md" <<EOF
---
spec_id: podcast-catalogue
success_criteria:
  - an episode is added
flows:
  - flow_id: ${flow_prefix}-001
    slug: add-an-episode
    name: An editor adds an episode.
    why: The catalogue is the product.
    test_path: tests/add.bats
scope_boundaries:
  always:
    - keep the feed valid
  ask_first: []
  never:
    - never drop an episode
clarifications:
  answered:
    - q: question one
      a: answer one
---
Body.
EOF

  run node "$REPO_ROOT/.gaia/scripts/spec/audit-render.mjs" --cache "$CACHE" \
    --routing "$BATS_TEST_TMPDIR/routing.json" --spec-id PODCAST-1 --out "$BATS_TEST_TMPDIR/AUDIT.md"
  [ "$status" -eq 0 ]
  [ -f "$BATS_TEST_TMPDIR/AUDIT.md" ]

  run bash "$REPO_ROOT/.gaia/scripts/spec/requirement-keys.sh" \
    --spec "$BATS_TEST_TMPDIR/SPEC.md" --audit "$BATS_TEST_TMPDIR/AUDIT.md"
  [ "$status" -eq 0 ]
  printf '%s\n' "$output" | grep -qx 'directive:1' || return 1
  printf '%s\n' "$output" | grep -qx 'directive:2' || return 1
  true
}
