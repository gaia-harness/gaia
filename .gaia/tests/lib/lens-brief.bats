#!/usr/bin/env bats
#
# Suite for .gaia/scripts/spec/lens-brief.mjs: the renderer that turns the
# audit docs (lens-dispatch.md, spec/audit.md, plan/decomposition-audit.md)
# into per-agent brief files and prints each agent's short prompt.
#
# The reference text for each equality check is built here with its own awk
# extraction from the docs, never through the script, so a slot or boundary
# bug in the script cannot also hide in the expectation.
#
# Assertion style: .claude/rules/bats-assertions.md.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  SCRIPT="$REPO_ROOT/.gaia/scripts/spec/lens-brief.mjs"
  REFERENCES=".claude/skills/gaia/references"
  DISPATCH="$REPO_ROOT/$REFERENCES/spec/lens-dispatch.md"
  AUDIT="$REPO_ROOT/$REFERENCES/spec/audit.md"
  DECOMPOSITION="$REPO_ROOT/$REFERENCES/plan/decomposition-audit.md"
  AUDIT_DIR="$BATS_TEST_TMPDIR/audit"
  SPEC_ARTIFACT="/scratch/draft.md"
  SPEC_ID="demo-spec"
  PLAN_ARTIFACT="/scratch/plan"
  SPEC_PATH="/scratch/SPEC.md"
  SPEC_LENSES="FG TST COV RT SEC MIG A11Y DOC PERF"
  PLAN_LENSES="DP CG COV TD"
}

# render_lens <kind> <id> [root]: runs `lens` and leaves status/output.
render_lens() {
  local kind="$1" id="$2" root="${3:-$REPO_ROOT}"
  if [ "$kind" = "spec" ]; then
    run node "$SCRIPT" lens --kind spec --lens "$id" --artifact "$SPEC_ARTIFACT" \
      --audit-dir "$AUDIT_DIR" --repo-root "$root" --spec-id "$SPEC_ID"
  else
    run node "$SCRIPT" lens --kind plan --lens "$id" --artifact "$PLAN_ARTIFACT" \
      --audit-dir "$AUDIT_DIR" --repo-root "$root" --spec-path "$SPEC_PATH"
  fi
}

# write_findings <kind> <id> <token>: a real findings file (empty array).
write_findings() {
  local file="$AUDIT_DIR/$1-$2.findings.json"
  if [ -n "$3" ]; then
    printf '{"dimension":"%s","brief_token":"%s","findings":[]}' "$2" "$3" >"$file"
  else
    printf '{"dimension":"%s","findings":[]}' "$2" >"$file"
  fi
  printf '%s\n' "$file"
}

token_of() {
  sed -n 's/.*"brief_token": "\([0-9a-f]\{32\}\)".*/\1/p' "$1"
}

# --- independent reference extraction -----------------------------------

# First blockquote run under a "## <heading>" of $1, `> ` stripped.
first_quote_under() {
  awk -v heading="$2" '
    index($0, heading) == 1 { inside = 1; next }
    inside && /^## / { exit }
    inside && /^>/ { print substr($0, ($0 ~ /^> /) ? 3 : 2); seen = 1; next }
    inside && seen { exit }
  ' "$1"
}

# Blockquote run that follows the line starting with label $2 in file $1.
labelled_quote() {
  awk -v label="$2" '
    index($0, label) == 1 { armed = 1; next }
    armed && /^>/ { print substr($0, ($0 ~ /^> /) ? 3 : 2); seen = 1; next }
    armed && seen { exit }
  ' "$1"
}

# Cell $3 (2 = label, 3 = spec, 4 = plan) of the Caller slots row whose label matches $2.
slot_cell() {
  awk -F'|' -v pattern="$2" -v column="$3" '
    /^## Caller slots/ { inside = 1; next }
    inside && /^## / { exit }
    inside && /^\|/ && $2 ~ pattern { gsub(/^ +| +$/, "", $column); print $column; exit }
  ' "$1"
}

# Focus text of the bullet with id $3 in file $1 (after its bold name).
bullet_focus() {
  awk -v id="$2" '
    /^- \*\*/ && index($0, "(id prefix `" id "`") > 0 { found = 1; sub(/^.*\)\.\*\* /, ""); print; next }
    found && ($0 == "" || /^ /) { print; next }
    found { exit }
  ' "$1"
}

bullet_name() {
  grep -F -- "(id prefix \`$2\`" "$1" | grep -E '^- \*\*' | head -n 1 |
    sed -E 's/^- \*\*(.*) \(id prefix `[A-Z0-9]+`.*$/\1/'
}

specialist_cell() {
  awk -F'|' -v id="$2" -v column="$3" '
    $2 ~ "^ *`" id "` *$" { gsub(/^ +| +$/, "", $column); print $column; exit }
  ' "$1"
}

# fill_caller <text> <artifact> <spec id>
fill_caller() {
  local value="$1"
  value="${value//<DRAFT_PATH>/"$2"}"
  value="${value//<PLAN_DIR>/"$2"}"
  value="${value//<spec_id>/"$3"}"
  printf '%s' "$value"
}

# reference_lens <kind> <id>: preamble, LENS line and focus text, no clause.
reference_lens() {
  local kind="$1" id="$2" column artifact name focus text
  local cell_artifact cell_read cell_target cell_evidence cell_dir cell_tool cell_critical cell_major cell_minor
  if [ "$kind" = "spec" ]; then column=3; artifact="$SPEC_ARTIFACT"; else column=4; artifact="$PLAN_ARTIFACT"; fi
  cell_artifact="$(fill_caller "$(slot_cell "$DISPATCH" '^ *Artifact under audit' "$column")" "$artifact" "$SPEC_ID")"
  cell_read="$(fill_caller "$(slot_cell "$DISPATCH" '^ *First Read' "$column")" "$artifact" "$SPEC_ID")"
  cell_target="$(slot_cell "$DISPATCH" '^ *Defect target' "$column")"
  cell_evidence="$(slot_cell "$DISPATCH" '^ *Evidence form' "$column")"
  cell_dir="$(fill_caller "$(slot_cell "$DISPATCH" '^ *Findings directory' "$column")" "$artifact" "$SPEC_ID")"
  cell_tool="$(slot_cell "$DISPATCH" '^ *Write tool' "$column")"
  cell_critical="$(slot_cell "$DISPATCH" '^ *`critical` *$' "$column")"
  cell_major="$(slot_cell "$DISPATCH" '^ *`major` *$' "$column")"
  cell_minor="$(slot_cell "$DISPATCH" '^ *`minor` *$' "$column")"
  text="$(first_quote_under "$DISPATCH" '## Shared preamble')"
  text="${text//<ARTIFACT>/"$cell_artifact"}"
  text="${text//<first Read>/"$cell_read"}"
  text="${text//<defect target>/"$cell_target"}"
  text="${text//<evidence form>/"$cell_evidence"}"
  text="${text//<FINDINGS_DIR>/"$cell_dir"}"
  text="${text//<write tool>/"$cell_tool"}"
  text="${text//<critical meaning>/"$cell_critical"}"
  text="${text//<major meaning>/"$cell_major"}"
  text="${text//<minor meaning>/"$cell_minor"}"
  text="${text//<LENS>/"$id"}"
  text="${text//<repo_root>/"$REPO_ROOT"}"

  if [ "$kind" = "spec" ]; then
    if [ -n "$(grep -E '^- \*\*' "$AUDIT" | grep -F -- "(id prefix \`$id\`")" ]; then
      name="$(bullet_name "$AUDIT" "$id")"
      focus="$(bullet_focus "$AUDIT" "$id")"
    else
      name="$(specialist_cell "$AUDIT" "$id" 3)"
      focus="$(specialist_cell "$AUDIT" "$id" 5)"
    fi
  else
    name="$(bullet_name "$DECOMPOSITION" "$id")"
    focus="$(bullet_focus "$DECOMPOSITION" "$id")"
    focus="${focus//<SPEC_PATH>/"$SPEC_PATH"}"
    focus="${focus//<PLAN_DIR>/"$PLAN_ARTIFACT"}"
    focus="${focus//<repo_root>/"$REPO_ROOT"}"
  fi
  printf '%s\n\nLENS: %s (id prefix %s)\n%s' "$text" "$name" "$id" "$focus"
}

# reference_refuter <kind> <shape> <ids> <verdicts> <findings> [refuter lens]
reference_refuter() {
  local kind="$1" shape="$2" ids="$3" verdicts="$4" findings="$5" lens="$6"
  local source prompt line out="" name
  if [ "$kind" = "spec" ]; then source="$AUDIT"; else source="$DECOMPOSITION"; fi
  prompt="$(awk '
    /^> Verify finding/ { inside = 1 }
    inside && /^>/ { print substr($0, ($0 ~ /^> /) ? 3 : 2); next }
    inside { exit }
  ' "$source")"
  if [ "$kind" = "spec" ]; then prompt="${prompt//<DRAFT_PATH>/"$SPEC_ARTIFACT"}"; else prompt="${prompt//<PLAN_DIR>/"$PLAN_ARTIFACT"}"; fi
  prompt="${prompt//<finding_id>/"${ids//,/, }"}"
  prompt="${prompt//<findings_file>/"$findings"}"
  prompt="${prompt//<verdict_file>/"${verdicts//,/, }"}"
  prompt="${prompt//<repo_root>/"$REPO_ROOT"}"
  line="$(labelled_quote "$DISPATCH" 'Verification lens line')"
  case "$shape" in
    deep) out="${line//<verification lens>/"$lens"}"$'\n\n' ;;
    deep-batched)
      for name in correctness security/safety reproduces-as-described; do
        out="$out${line//<verification lens>/"$name"}"$'\n'
      done
      out="$out"$'\n'
      ;;
  esac
  out="$out$prompt"
  case "$shape" in
    batched | deep-batched) out="$out"$'\n\n'"$(labelled_quote "$DISPATCH" 'Batched refuter instruction')" ;;
  esac
  printf '%s' "$out"
}

# brief_without_clause <brief file>: the brief minus its appended clause.
brief_without_clause() {
  awk '
    /^After your first Read, read the `## Findings file schema`/ { exit }
    { print }
  ' "$1"
}

scratch_root() {
  local root="$BATS_TEST_TMPDIR/root"
  mkdir -p "$root/$REFERENCES/spec" "$root/$REFERENCES/plan"
  cp "$DISPATCH" "$AUDIT" "$root/$REFERENCES/spec/"
  cp "$DECOMPOSITION" "$root/$REFERENCES/plan/"
  printf '%s\n' "$root"
}

@test "short prompt opens with a Read of the rendered brief" {
  local brief
  render_lens spec FG
  [ "$status" -eq 0 ] || return 1
  brief="$AUDIT_DIR/briefs/spec-FG.md"
  [ -f "$brief" ] || return 1
  case "$output" in
    "You are the Factual grounding (FG) lens of the SPEC audit. Your first action is a Read of $brief; follow it."*) ;;
    *) printf 'short prompt was: %s\n' "$output" >&2; return 1 ;;
  esac

  local findings token
  token="$(token_of "$brief")"
  findings="$(write_findings spec FG "$token")"
  run node "$SCRIPT" refuter --kind spec --lens FG --findings "$findings" --brief "$brief" \
    --audit-dir "$AUDIT_DIR" --artifact "$SPEC_ARTIFACT" --repo-root "$REPO_ROOT" \
    --shape single --ids FG-001 --verdicts "$AUDIT_DIR/verdicts/FG-001.json"
  [ "$status" -eq 0 ] || return 1
  brief="$AUDIT_DIR/briefs/refuter-spec-FG-FG-001.md"
  [ -f "$brief" ] || return 1
  case "$output" in
    "You are a refuter in the SPEC audit. Your first action is a Read of $brief; follow it."*) ;;
    *) printf 'refuter short prompt was: %s\n' "$output" >&2; return 1 ;;
  esac
}

@test "brief plus short prompt equals the interpolated prompt plus the clause for every lens and refuter" {
  local kind id expected actual brief rest findings token shape ids verdicts lens slug
  for kind in spec plan; do
    if [ "$kind" = "spec" ]; then ids_of_lenses="$SPEC_LENSES"; else ids_of_lenses="$PLAN_LENSES"; fi
    for id in $ids_of_lenses; do
      render_lens "$kind" "$id"
      [ "$status" -eq 0 ] || { printf 'render %s %s failed: %s\n' "$kind" "$id" "$output" >&2; return 1; }
      brief="$AUDIT_DIR/briefs/$kind-$id.md"
      expected="$(reference_lens "$kind" "$id")"
      actual="$(brief_without_clause "$brief")"
      [ "$actual" = "$expected" ] || { printf 'lens %s %s differs\n' "$kind" "$id" >&2; diff <(printf '%s\n' "$expected") <(printf '%s\n' "$actual") >&2; return 1; }
      rest="$(cat "$brief")"
      [ "${#rest}" -gt "${#expected}" ] || return 1
      case "${rest:${#expected}}" in
        $'\n\n'"After your first Read, read the "*) ;;
        *) printf 'lens %s %s lacks the appended clause\n' "$kind" "$id" >&2; return 1 ;;
      esac
    done
  done

  for kind in spec plan; do
    render_lens "$kind" "$([ "$kind" = spec ] && echo FG || echo TD)"
    [ "$status" -eq 0 ] || return 1
    id="$([ "$kind" = spec ] && echo FG || echo TD)"
    token="$(token_of "$AUDIT_DIR/briefs/$kind-$id.md")"
    findings="$(write_findings "$kind" "$id" "$token")"
    for shape in single deep batched deep-batched; do
      lens=""
      slug=""
      case "$shape" in
        single | deep) ids="$id-001"; verdicts="$AUDIT_DIR/verdicts/$id-001.json" ;;
        *) ids="$id-001,$id-002"; verdicts="$AUDIT_DIR/verdicts/$id-001.json,$AUDIT_DIR/verdicts/$id-002.json" ;;
      esac
      if [ "$shape" = "deep" ]; then lens="security/safety"; slug="-security-safety"; fi
      run node "$SCRIPT" refuter --kind "$kind" --lens "$id" --findings "$findings" \
        --brief "$AUDIT_DIR/briefs/$kind-$id.md" --audit-dir "$AUDIT_DIR" \
        --artifact "$([ "$kind" = spec ] && echo "$SPEC_ARTIFACT" || echo "$PLAN_ARTIFACT")" \
        --repo-root "$REPO_ROOT" --shape "$shape" --ids "$ids" --verdicts "$verdicts" \
        ${lens:+--refuter-lens "$lens"}
      [ "$status" -eq 0 ] || { printf 'refuter %s %s failed: %s\n' "$kind" "$shape" "$output" >&2; return 1; }
      brief="$AUDIT_DIR/briefs/refuter-$kind-$id-${ids%%,*}$slug.md"
      [ -f "$brief" ] || { printf 'no refuter brief %s\n' "$brief" >&2; return 1; }
      expected="$(reference_refuter "$kind" "$shape" "$ids" "$verdicts" "$findings" "$lens")"
      actual="$(cat "$brief")"
      [ "$actual" = "$expected" ] || { printf 'refuter %s %s differs\n' "$kind" "$shape" >&2; diff <(printf '%s\n' "$expected") <(printf '%s\n' "$actual") >&2; return 1; }
    done
  done
}

@test "refuter brief is refused with no file when the lens findings file is not real" {
  local brief token findings case_name
  render_lens spec FG
  [ "$status" -eq 0 ] || return 1
  brief="$AUDIT_DIR/briefs/spec-FG.md"
  token="$(token_of "$brief")"
  for case_name in missing no-token wrong-token no-findings-key; do
    mkdir -p "$AUDIT_DIR/briefs"
    printf 'stale\n' >"$AUDIT_DIR/briefs/refuter-spec-FG-FG-001.md"
    findings="$AUDIT_DIR/spec-FG.findings.json"
    rm -f "$findings"
    case "$case_name" in
      no-token) write_findings spec FG "" >/dev/null ;;
      wrong-token) write_findings spec FG "00000000000000000000000000000000" >/dev/null ;;
      no-findings-key) printf '{"dimension":"FG","brief_token":"%s"}' "$token" >"$findings" ;;
    esac
    run node "$SCRIPT" refuter --kind spec --lens FG --findings "$findings" --brief "$brief" \
      --audit-dir "$AUDIT_DIR" --artifact "$SPEC_ARTIFACT" --repo-root "$REPO_ROOT" \
      --shape single --ids FG-001 --verdicts "$AUDIT_DIR/verdicts/FG-001.json"
    [ "$status" -eq 1 ] || { printf '%s: status %s\n' "$case_name" "$status" >&2; return 1; }
    [ -e "$AUDIT_DIR/briefs/refuter-spec-FG-FG-001.md" ] && { printf '%s left a brief\n' "$case_name" >&2; return 1; }
  done
  true
}

@test "brief derives from the source docs at render time" {
  local root brief
  root="$(scratch_root)"
  sed -i.bak 's/Be concrete and falsifiable\./Be concrete and DERIVED-PREAMBLE./' "$root/$REFERENCES/spec/lens-dispatch.md"
  sed -i.bak 's/Treat the SPEC as a set of factual claims/Treat the SPEC as DERIVED-FOCUS claims/' "$root/$REFERENCES/spec/audit.md"
  sed -i.bak 's/It never asks for a new test, a test file/DERIVED-RULES never asks for a new test, a test file/' "$root/$REFERENCES/spec/audit.md"
  sed -i.bak 's/^> After your first Read, read the `## Findings file schema` section of `.claude\/skills\/gaia\/references\/spec\/lens-dispatch.md` for the file.s shape\. Set/> DERIVED-CLAUSE Set/' "$root/$REFERENCES/spec/lens-dispatch.md"
  sed -i.bak 's/Read the finding there;/DERIVED-REFUTER Read the finding there;/' "$root/$REFERENCES/spec/audit.md"
  render_lens spec FG "$root"
  [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; return 1; }
  brief="$AUDIT_DIR/briefs/spec-FG.md"
  grep -qF 'DERIVED-PREAMBLE' "$brief" || return 1
  grep -qF 'DERIVED-FOCUS' "$brief" || return 1
  grep -qF 'DERIVED-RULES' "$brief" || return 1
  grep -qF 'DERIVED-CLAUSE' "$brief" || return 1
  local findings token
  token="$(token_of "$brief")"
  findings="$(write_findings spec FG "$token")"
  run node "$SCRIPT" refuter --kind spec --lens FG --findings "$findings" --brief "$brief" \
    --audit-dir "$AUDIT_DIR" --artifact "$SPEC_ARTIFACT" --repo-root "$root" \
    --shape single --ids FG-001 --verdicts "$AUDIT_DIR/verdicts/FG-001.json"
  [ "$status" -eq 0 ] || return 1
  grep -qF 'DERIVED-REFUTER' "$AUDIT_DIR/briefs/refuter-spec-FG-FG-001.md" || return 1
  # A specialist table row's `Hunts for` cell and a plan lens bullet derive the same way.
  sed -i.bak 's/unsafe deserialization;/DERIVED-ROW deserialization;/' "$root/$REFERENCES/spec/audit.md"
  sed -i.bak 's/Name each check that fails:/Name each DERIVED-PLAN check that fails:/' "$root/$REFERENCES/plan/decomposition-audit.md"
  render_lens spec SEC "$root"
  [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; return 1; }
  grep -qF 'DERIVED-ROW' "$AUDIT_DIR/briefs/spec-SEC.md" || return 1
  render_lens plan TD "$root"
  [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; return 1; }
  grep -qF 'DERIVED-PLAN' "$AUDIT_DIR/briefs/plan-TD.md" || return 1
  # The real docs are untouched by the scratch edits.
  grep -qF 'DERIVED' "$DISPATCH" && return 1
  true
}

@test "render refuses an unfilled slot or empty output and pre-clears the brief" {
  local root brief
  mkdir -p "$AUDIT_DIR/briefs"

  # Pass cases: real docs carry literal angle-bracket text no slot owns.
  render_lens plan TD
  [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; return 1; }
  grep -qF -- '--touched <file>' "$AUDIT_DIR/briefs/plan-TD.md" || return 1
  grep -qF '`<title>`' "$AUDIT_DIR/briefs/plan-TD.md" || return 1
  render_lens spec FG
  [ "$status" -eq 0 ] || return 1
  grep -qF '"<Label>: <value>"' "$AUDIT_DIR/briefs/spec-FG.md" || return 1

  # A listed slot left unfilled: plan COV names <SPEC_PATH>, none given.
  printf 'stale\n' >"$AUDIT_DIR/briefs/plan-COV.md"
  run node "$SCRIPT" lens --kind plan --lens COV --artifact "$PLAN_ARTIFACT" \
    --audit-dir "$AUDIT_DIR" --repo-root "$REPO_ROOT"
  [ "$status" -eq 1 ] || return 1
  [ -e "$AUDIT_DIR/briefs/plan-COV.md" ] && return 1

  # Unknown lens.
  printf 'stale\n' >"$AUDIT_DIR/briefs/spec-NOPE.md"
  render_lens spec NOPE
  [ "$status" -eq 1 ] || return 1
  [ -e "$AUDIT_DIR/briefs/spec-NOPE.md" ] && return 1

  # Empty focus.
  root="$(scratch_root)"
  sed -i.bak 's/^\(- \*\*Factual grounding (id prefix `FG`)\.\*\*\) .*$/\1 /' "$root/$REFERENCES/spec/audit.md"
  printf 'stale\n' >"$AUDIT_DIR/briefs/spec-FG.md"
  render_lens spec FG "$root"
  [ "$status" -eq 1 ] || { printf 'empty focus status %s\n' "$status" >&2; return 1; }
  [ -e "$AUDIT_DIR/briefs/spec-FG.md" ] && return 1

  # Empty preamble.
  root="$BATS_TEST_TMPDIR/empty-preamble"
  mkdir -p "$root/$REFERENCES/spec" "$root/$REFERENCES/plan"
  cp "$AUDIT" "$root/$REFERENCES/spec/"
  cp "$DECOMPOSITION" "$root/$REFERENCES/plan/"
  grep -v '^>' "$DISPATCH" >"$root/$REFERENCES/spec/lens-dispatch.md"
  render_lens spec FG "$root"
  [ "$status" -eq 1 ] || return 1

  # Usage errors: spec needs --spec-id.
  run node "$SCRIPT" lens --kind spec --lens FG --artifact "$SPEC_ARTIFACT" \
    --audit-dir "$AUDIT_DIR" --repo-root "$REPO_ROOT"
  [ "$status" -eq 2 ] || return 1
  [ -e "$AUDIT_DIR/briefs/spec-FG.md" ] && return 1
  true
}

@test "classify reads a missing or wrong brief token as a no-op" {
  local brief token findings
  render_lens spec FG
  [ "$status" -eq 0 ] || return 1
  brief="$AUDIT_DIR/briefs/spec-FG.md"
  token="$(token_of "$brief")"
  [ "${#token}" -eq 32 ] || return 1

  findings="$(write_findings spec FG "$token")"
  run node "$SCRIPT" classify --findings "$findings" --brief "$brief"
  [ "$status" -eq 0 ] || return 1

  findings="$(write_findings spec FG "")"
  run node "$SCRIPT" classify --findings "$findings" --brief "$brief"
  [ "$status" -eq 1 ] || return 1

  findings="$(write_findings spec FG "00000000000000000000000000000000")"
  run node "$SCRIPT" classify --findings "$findings" --brief "$brief"
  [ "$status" -eq 1 ] || return 1

  rm -f "$findings"
  run node "$SCRIPT" classify --findings "$findings" --brief "$brief"
  [ "$status" -eq 1 ] || return 1

  printf '{"dimension":"FG","brief_token":"%s"}' "$token" >"$findings"
  run node "$SCRIPT" classify --findings "$findings" --brief "$brief"
  [ "$status" -eq 1 ] || return 1

  # Without a brief the token is not checked.
  findings="$(write_findings spec FG "")"
  run node "$SCRIPT" classify --findings "$findings"
  [ "$status" -eq 0 ] || return 1
}

@test "the output-format clause carries the directive rules and the per-kind field rules" {
  local rules brief
  rules="$(awk '/^- \*\*Plan-time directive\*\*/ { i = index($0, "Write it as the property a test proves"); print substr($0, i); exit }' "$AUDIT")"
  [ -n "$rules" ] || return 1

  render_lens spec FG
  [ "$status" -eq 0 ] || return 1
  brief="$(cat "$AUDIT_DIR/briefs/spec-FG.md")"
  case "$brief" in *"$rules"*) ;; *) printf 'directive rules missing from the SPEC brief\n' >&2; return 1 ;; esac
  case "$brief" in *'`proposed_disposition`'*'`plan_directive`'*'`directive` only on a finding you propose as `plan_directive`'*) ;; *) return 1 ;; esac
  case "$brief" in *'`row_patches`'*) return 1 ;; esac
  case "$brief" in *'<DIRECTIVE_RULES>'* | *'<BRIEF_TOKEN>'*) return 1 ;; esac
  [ -n "$(token_of "$AUDIT_DIR/briefs/spec-FG.md")" ] || return 1

  render_lens plan TD
  [ "$status" -eq 0 ] || return 1
  brief="$(cat "$AUDIT_DIR/briefs/plan-TD.md")"
  case "$brief" in *'`proposed_disposition`'*'`apply`'*'`structural`'*'`row_patches` and `replacements` only on a fix you recommend applying'*) ;; *) return 1 ;; esac
  case "$brief" in *"$rules"*) return 1 ;; esac
  case "$brief" in *'`plan_directive`'*) return 1 ;; esac
  case "$brief" in *'<DIRECTIVE_RULES>'* | *'<BRIEF_TOKEN>'*) return 1 ;; esac
  [ -n "$(token_of "$AUDIT_DIR/briefs/plan-TD.md")" ] || return 1
  true
}
