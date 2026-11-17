#!/usr/bin/env bats
# Suite for .gaia/scripts/spec/audit-render.mjs: renders the SPEC audit report
# from the routing record plus the findings, verdicts and coverage files of an
# audit cache. Every fixture is built in $BATS_TEST_TMPDIR from neutral
# domains (a community garden booking app, a podcast catalogue).
#
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  RENDER="$REPO_ROOT/.gaia/scripts/spec/audit-render.mjs"
  KEYS_SCRIPT="$REPO_ROOT/.gaia/scripts/spec/requirement-keys.sh"
  CACHE="$BATS_TEST_TMPDIR/cache"
  ROUTING="$BATS_TEST_TMPDIR/routing.json"
  OUT="$BATS_TEST_TMPDIR/AUDIT.md"
  SPEC="$BATS_TEST_TMPDIR/SPEC.md"
  mkdir -p "$CACHE/findings" "$CACHE/verdicts"
}

# build_fixture <full|legacy>: writes the cache and routing record. "full"
# carries lens-written directive and proposed_disposition fields; "legacy"
# omits both, so the routing record carries every directive_text and every
# minor's disposition.
build_fixture() {
  FIXTURE_SHAPE="$1" CACHE="$CACHE" ROUTING="$ROUTING" node --input-type=module - <<'NODE'
import {writeFileSync} from 'node:fs';
const full = process.env.FIXTURE_SHAPE === 'full';
const cache = process.env.CACHE;
const write = (path, value) => writeFileSync(`${cache}/${path}`, JSON.stringify(value, null, 2));
const finding = (id, severity, title, evidence, extra = {}) => ({
  id, severity, title, location: 'booking.md:1', issue: `${title} issue`,
  evidence, recommendation: `${title} fix`, ...extra,
});

if (full) {
  write('findings/booking.json', {dimension: 'booking', findings: [
    finding('BKG-001', 'major', 'Double booking', 'plots.ts:12\nsecond line', {proposed_disposition: 'plan_directive', directive: 'A second booking of the same plot and day is refused with 409 and changes nothing'}),
    finding('BKG-002', 'major', 'Missing season end', 'seasons.ts:4', {proposed_disposition: 'spec_defect', directive: 'Spec defect carrying a directive field'}),
    finding('BKG-003', 'major', 'Phantom waitlist', 'waitlist.ts:9', {proposed_disposition: 'plan_directive', directive: 'Refuted directive text'}),
    finding('BKG-004', 'major', 'Overbroad cancel', 'cancel.ts:30', {proposed_disposition: 'plan_directive', directive: 'Cancelling any booking cancels every booking'}),
    finding('BKG-005', 'minor', 'Vague unit', 'units.md:2'),
    finding('BKG-006', 'minor', 'Odd heading', 'doc.md:1'),
    finding('BKG-007', 'minor', 'Late notice', 'notice.ts:3', {proposed_disposition: 'plan_directive', directive: 'A notice sent after the season ends names the closed season'}),
    finding('BKG-008', 'minor', 'Rename label', 'label.ts:8', {proposed_disposition: 'spec_defect'}),
    finding('BKG-009', 'minor', 'Wording', 'copy.md:5', {proposed_disposition: 'plan_directive', directive: 'Proposal overridden by routing'}),
    finding('BKG-010', 'major', 'Quota ignored', 'quota.ts:7', {proposed_disposition: 'spec_defect'}),
  ]});
} else {
  write('findings/booking.json', {dimension: 'booking', findings: [
    finding('BKG-001', 'major', 'Double booking', 'plots.ts:12\nsecond line'),
    finding('BKG-002', 'major', 'Missing season end', 'seasons.ts:4'),
    finding('BKG-003', 'major', 'Phantom waitlist', 'waitlist.ts:9'),
    finding('BKG-004', 'major', 'Overbroad cancel', 'cancel.ts:30'),
    finding('BKG-005', 'minor', 'Vague unit', 'units.md:2'),
    finding('BKG-006', 'minor', 'Odd heading', 'doc.md:1'),
    finding('BKG-007', 'minor', 'Late notice', 'notice.ts:3'),
    finding('BKG-008', 'minor', 'Rename label', 'label.ts:8'),
    finding('BKG-009', 'minor', 'Wording', 'copy.md:5'),
    finding('BKG-010', 'major', 'Quota ignored', 'quota.ts:7'),
  ]});
}
write('findings/alerts.json', {dimension: 'alerts', findings: [
  finding('ALR-001', 'major', 'Silent reminder failure', 'reminders.ts:21'),
]});
write('findings/completeness.json', {dimension: 'completeness', findings: [
  finding('CPL-001', 'major', 'No guest limit', 'guests.ts:2'),
]});
write('findings/self-review.json', {dimension: 'self-review', findings: [
  finding('SR-001', 'major', 'Self review only', 'draft.md:1', {directive: 'Never rendered'}),
]});

write('verdicts/BKG-001.json', {verdict: 'confirmed', corrected_severity: 'major', disposition: 'plan_directive', reasoning: 'Confirmed.', evidence: 'plots.ts:12'});
write('verdicts/BKG-003-correctness.json', {verdict: 'partial', corrected_severity: 'minor', reasoning: 'Wrong verdict file.', evidence: 'x'});
write('verdicts/BKG-003-reproduces-as-described.json', {verdict: 'refuted', corrected_severity: 'none', reasoning: 'The waitlist is never reachable.\nSecond reasoning line.', evidence: 'waitlist.ts:9'});
write('verdicts/BKG-003-security-safety.json', {verdict: 'refuted', corrected_severity: 'none', reasoning: 'Later slug.', evidence: 'x'});
write('verdicts/BKG-004.json', {verdict: 'partial', corrected_severity: 'minor', disposition: 'plan_directive', reasoning: 'Only the owner can cancel, so the reach is narrower.', evidence: 'cancel.ts:30'});

const plan = (id, directiveText = null) => ({id, status: 'survived', corrected_severity: 'major', verdict: 'confirmed', disposition: 'plan_directive', decision: null, folded_text: null, directive_text: directiveText});
const fix = (id, decision, foldedText = null, severity = 'major') => ({id, status: 'survived', corrected_severity: severity, verdict: 'confirmed', disposition: 'spec_defect', decision, folded_text: foldedText, directive_text: null});
const entries = [
  plan('BKG-001', full ? null : 'A second booking of the same plot and day is refused with 409 and changes nothing'),
  fix('BKG-002', 'apply', 'season end was missing -> season end added to the intent'),
  {id: 'BKG-003', status: 'refuted', corrected_severity: 'none', verdict: 'refuted', disposition: null, decision: null, folded_text: null, directive_text: null},
  {...plan('BKG-004', 'Cancelling a booking cancels only that booking'), corrected_severity: 'minor', verdict: 'partial'},
  {...fix('BKG-005', 'keep', null, 'minor'), verdict: null},
  {id: 'BKG-008', status: 'survived', corrected_severity: null, verdict: null, disposition: full ? null : 'spec_defect', decision: 'apply', folded_text: 'label renamed -> label reads Plot', directive_text: null},
  {...fix('BKG-009', 'keep', null, 'minor'), verdict: null},
  plan('BKG-010', 'A booking over the plot quota is refused with 422'),
  fix('ALR-001', 'deferred'),
  plan('CPL-001', 'A guest beyond the plot limit is refused with 422'),
];
if (!full) {
  entries.push({id: 'BKG-007', status: 'survived', corrected_severity: null, verdict: null, disposition: 'plan_directive', decision: null, folded_text: null, directive_text: 'A notice sent after the season ends names the closed season'});
}
writeFileSync(process.env.ROUTING, JSON.stringify({tier: 'deep', verdict: 'Plannable after the folds. The premise is sound.', findings: entries}, null, 2));

const records = [
  {phase: 'self-review', lens: 'self-review', disposition: 'first_pass'},
  {phase: 'lens', lens: 'booking', disposition: 'first_pass'},
  {phase: 'lens', lens: 'alerts', disposition: 'first_pass'},
  {phase: 'refuter', lens: 'booking', disposition: 'first_pass'},
  {phase: 'completeness', lens: 'critic', disposition: 'not_applicable'},
];
writeFileSync(`${cache}/coverage.jsonl`, `${records.map((record) => JSON.stringify(record)).join('\n')}\n`);
NODE
}

render() {
  run node "$RENDER" --cache "$CACHE" --routing "$ROUTING" --spec-id GARDEN-1 --out "$OUT"
}

write_spec() {
  cat >"$SPEC" <<'EOF'
---
spec_id: SPEC-900
success_criteria:
  - a booking is made
flows:
  - flow_id: FLOW-001
    slug: book-a-plot
    name: A member books a plot.
    why: Booking is the product.
    test_path: tests/book.bats
scope_boundaries:
  always:
    - keep the season rules
  ask_first: []
  never:
    - never double book
clarifications:
  answered:
    - q: question one
      a: answer one
---
Body.
EOF
}

# directive_lines <file>: the directive lines of the plan-time section.
directive_lines() {
  awk '/^## /{in_section = ($0 ~ /^## Plan-time directives/); next} in_section && /^[0-9]+\. /' "$1"
}

# section_bullets <file> <heading prefix>: the "- " lines of one section.
section_bullets() {
  awk -v prefix="$2" '/^## /{in_section = (index($0, "## " prefix) == 1); next} in_section && /^- /' "$1"
}

@test "render places each finding under its heading exactly once" {
  build_fixture full
  write_spec
  render
  [ "$status" -eq 0 ] || return 1
  [ -f "$OUT" ] || return 1

  [ "$(directive_lines "$OUT" | wc -l | tr -d ' ')" = "5" ] || return 1
  for id in BKG-001 BKG-004 BKG-007 BKG-010 CPL-001; do
    [ "$(directive_lines "$OUT" | grep -c -- "($id")" = "1" ] || return 1
  done
  for id in ALR-001 BKG-002 BKG-005 BKG-008 BKG-009; do
    [ "$(section_bullets "$OUT" 'SPEC contract fixes' | grep -c -- "^- $id:")" = "1" ] || return 1
  done
  for id in BKG-003 BKG-004; do
    [ "$(section_bullets "$OUT" 'Refuted / downgraded' | grep -c -- "^- $id:")" = "1" ] || return 1
  done
  [ "$(grep -c 'BKG-006' "$OUT")" = "1" ] || return 1
  grep -qF 'Not routed (minor, no verdict or disposition): BKG-006' "$OUT" || return 1
  grep -qF -- "- **lens** (\`alerts\`): \`first_pass\`" "$OUT" || return 1
  grep -qF 'SR-001' "$OUT" && return 1

  run bash "$KEYS_SCRIPT" --spec "$SPEC" --audit "$OUT"
  [ "$status" -eq 0 ] || return 1
  [ "$(grep -c '^directive:' <<<"$output")" = "5" ] || return 1
  for number in 1 2 3 4 5; do
    grep -qx "directive:$number" <<<"$output" || return 1
  done
}

@test "render reproduces the directives and folded fixes of a hand-written report" {
  build_fixture legacy
  render
  [ "$status" -eq 0 ] || return 1

  cat >"$BATS_TEST_TMPDIR/hand-written.md" <<'EOF'
# GARDEN-1 Adversarial Audit

2 lenses, 12 findings raised.

## Verdict

Plannable after the folds. The premise is sound.

## Plan-time directives (no SPEC change)

These satisfy the SPEC's binding contracts; the plan and implementation must honor them.

1. A second booking of the same plot and day is refused with 409 and changes nothing (BKG-001; plots.ts:12 second line)
2. Cancelling a booking cancels only that booking (BKG-004; cancel.ts:30)
3. A notice sent after the season ends names the closed season (BKG-007; notice.ts:3)
4. A booking over the plot quota is refused with 422 (BKG-010; quota.ts:7)
5. A guest beyond the plot limit is refused with 422 (CPL-001; guests.ts:2)

## SPEC contract fixes (folded into the draft pre-save)

- BKG-002: season end was missing -> season end added to the intent
- BKG-005: not folded (kept): Vague unit
- BKG-008: label renamed -> label reads Plot
- BKG-009: not folded (kept): Wording
- ALR-001: deferred for human review: Silent reminder failure

## Refuted / downgraded (for the record)

- BKG-003: refuted (none): The waitlist is never reachable.

## Coverage

- **lens** (`booking`): `first_pass`
EOF
  local hand="$BATS_TEST_TMPDIR/hand-written.md"
  local rendered_directives hand_directives rendered_fixes hand_fixes
  rendered_directives="$(directive_lines "$OUT" | sed -E 's/^[0-9]+\. //' | LC_ALL=C sort)"
  hand_directives="$(directive_lines "$hand" | sed -E 's/^[0-9]+\. //' | LC_ALL=C sort)"
  [ "$rendered_directives" = "$hand_directives" ] || return 1
  [ -z "$(directive_lines "$OUT" | sed -E 's/^[0-9]+\. //' | LC_ALL=C sort | uniq -d)" ] || return 1

  rendered_fixes="$(section_bullets "$OUT" 'SPEC contract fixes' | LC_ALL=C sort)"
  hand_fixes="$(section_bullets "$hand" 'SPEC contract fixes' | LC_ALL=C sort)"
  [ "$(wc -l <<<"$rendered_fixes" | tr -d " ")" = "5" ] || return 1
  [ "$(wc -l <<<"$rendered_directives" | tr -d " ")" = "5" ] || return 1
  [ "$rendered_fixes" = "$hand_fixes" ] || return 1
  [ -z "$(section_bullets "$OUT" 'SPEC contract fixes' | LC_ALL=C sort | uniq -d)" ] || return 1
}

@test "render keeps the template headings and numbers directives deterministically" {
  build_fixture full
  render
  [ "$status" -eq 0 ] || return 1

  local expected_headings actual_headings
  expected_headings="$(printf '%s\n' '## Verdict' '## Plan-time directives (no SPEC change)' '## SPEC contract fixes (folded into the draft pre-save)' '## Refuted / downgraded (for the record)' '## Coverage')"
  actual_headings="$(grep '^## ' "$OUT")"
  [ "$actual_headings" = "$expected_headings" ] || return 1
  [ "$(head -n 1 "$OUT")" = '# GARDEN-1 Adversarial Audit' ] || return 1
  grep -qxF "These satisfy the SPEC's binding contracts; the plan and implementation must honor them." "$OUT" || return 1
  grep -qF '2 lenses (Deep tier), 12 findings raised, 10 survived verification, 1 refuted; survivor severity after verification: 0 critical / 5 major / 5 minor' "$OUT" || return 1

  local order
  order="$(directive_lines "$OUT" | sed -E 's/^([0-9]+)\. .*\((BKG-[0-9]+|CPL-[0-9]+).*$/\1 \2/' | tr '\n' ',')"
  [ "$order" = "1 BKG-001,2 BKG-004,3 BKG-007,4 BKG-010,5 CPL-001," ] || return 1
  grep -qxF '1. A second booking of the same plot and day is refused with 409 and changes nothing (BKG-001; plots.ts:12 second line)' "$OUT" || return 1
  grep -qxF '2. Cancelling a booking cancels only that booking (BKG-004; cancel.ts:30)' "$OUT" || return 1
  grep -qxF -- '- BKG-004: partial (minor): Only the owner can cancel, so the reach is narrower.' "$OUT" || return 1
  grep -qxF -- '- BKG-003: refuted (none): The waitlist is never reachable.' "$OUT" || return 1

  # Arrival order of findings and routing entries changes nothing.
  local first="$BATS_TEST_TMPDIR/first.md"
  cp "$OUT" "$first"
  CACHE="$CACHE" ROUTING="$ROUTING" node --input-type=module - <<'NODE'
import {readFileSync, writeFileSync} from 'node:fs';
const routing = JSON.parse(readFileSync(process.env.ROUTING, 'utf8'));
routing.findings.reverse();
writeFileSync(process.env.ROUTING, JSON.stringify(routing));
const path = `${process.env.CACHE}/findings/booking.json`;
const lens = JSON.parse(readFileSync(path, 'utf8'));
lens.findings.reverse();
writeFileSync(path, JSON.stringify(lens));
NODE
  render
  [ "$status" -eq 0 ] || return 1
  cmp -s "$first" "$OUT" || return 1
}

@test "render refuses a directive that would break the list and renders only surviving plan-time directives" {
  local bad_text
  for bad_text in $'first line\nsecond line' '# heading start' '7. numbered start'; do
    build_fixture full
    BAD_TEXT="$bad_text" ROUTING="$ROUTING" node --input-type=module - <<'NODE'
import {readFileSync, writeFileSync} from 'node:fs';
const routing = JSON.parse(readFileSync(process.env.ROUTING, 'utf8'));
routing.findings.find((entry) => entry.id === 'BKG-010').directive_text = process.env.BAD_TEXT;
writeFileSync(process.env.ROUTING, JSON.stringify(routing));
NODE
    rm -f "$OUT"
    render
    [ "$status" -eq 1 ] || return 1
    [ ! -e "$OUT" ] || return 1
    [ "$(grep -c 'BKG-010' <<<"$output")" = "1" ] || return 1
  done

  # A lens field on a refuted finding or a spec defect never becomes a directive.
  build_fixture full
  render
  [ "$status" -eq 0 ] || return 1
  grep -qF 'Refuted directive text' "$OUT" && return 1
  grep -qF 'Spec defect carrying a directive field' "$OUT" && return 1
  grep -qF 'Proposal overridden by routing' "$OUT" && return 1
  true
}

@test "render exits naming a plan-time directive with no text" {
  build_fixture legacy
  ROUTING="$ROUTING" node --input-type=module - <<'NODE'
import {readFileSync, writeFileSync} from 'node:fs';
const routing = JSON.parse(readFileSync(process.env.ROUTING, 'utf8'));
routing.findings.find((entry) => entry.id === 'CPL-001').directive_text = null;
writeFileSync(process.env.ROUTING, JSON.stringify(routing));
NODE
  rm -f "$OUT"
  render
  [ "$status" -eq 1 ] || return 1
  [ ! -e "$OUT" ] || return 1
  grep -qF 'CPL-001' <<<"$output" || return 1
}

@test "a minor finding takes its disposition from its lens proposal" {
  build_fixture full
  render
  [ "$status" -eq 0 ] || return 1

  # BKG-007 has no routing entry and its lens proposed a directive.
  grep -qF 'A notice sent after the season ends names the closed season (BKG-007; notice.ts:3)' <<<"$(directive_lines "$OUT")" || return 1
  # BKG-008 has a routing entry with no disposition and its lens proposed a spec defect.
  grep -qxF -- '- BKG-008: label renamed -> label reads Plot' <<<"$(section_bullets "$OUT" 'SPEC contract fixes')" || return 1
  # BKG-009: a routing disposition wins over the lens proposal.
  grep -qxF -- '- BKG-009: not folded (kept): Wording' <<<"$(section_bullets "$OUT" 'SPEC contract fixes')" || return 1
  grep -qF 'BKG-009' <<<"$(directive_lines "$OUT")" && return 1
  # BKG-006 has neither: listed as not routed, and nowhere else.
  grep -qxF 'Not routed (minor, no verdict or disposition): BKG-006' "$OUT" || return 1
  [ "$(grep -c 'BKG-006' "$OUT")" = "1" ] || return 1
}
