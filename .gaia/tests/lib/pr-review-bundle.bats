#!/usr/bin/env bats
#
# Suite for .gaia/scripts/pr-review-bundle.sh, the builder of the one input
# bundle the pull request reviewer reads. Each case drives the script through
# its arguments, exit status, output and the files it writes, over a throwaway
# repository with a stub `gh` on PATH that logs every call. The record and
# section halves of the cases drive pr-review-record.sh and pr-review-gate.sh.
#
# Maintainer-only. `.gaia/tests` is release-excluded, so this never reaches an
# adopter.
#
# Run: .gaia/scripts/bats5.sh .gaia/tests/lib/pr-review-bundle.bats < /dev/null
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

bats_require_minimum_version 1.5.0

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  SCRIPTS="$REPO_ROOT/.gaia/scripts"
  BUNDLE_SCRIPT="$SCRIPTS/pr-review-bundle.sh"
  # shellcheck source=/dev/null
  . "$REPO_ROOT/.gaia/tests/helpers/audit-loop-fixture.sh"
  # shellcheck source=/dev/null
  . "$SCRIPTS/pr-body-sections-lib.sh"
  alf_init

  GH_DIR="$BATS_TEST_TMPDIR/gh"
  GH_LOG="$GH_DIR/calls.log"
  mkdir -p "$GH_DIR/bin"
  : >"$GH_LOG"
  printf 'false\n' >"$GH_DIR/fork-answer"
  cat >"$GH_DIR/bin/gh" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >>"$GH_LOG"
case "$1 $2" in
  "pr view")
    case "$*" in
      *isCrossRepository*) [ -z "${GH_UNANSWERABLE:-}" ] || exit 1; cat "$GH_DIR/fork-answer" ;;
      *) cat "$GH_DIR/pr.json" ;;
    esac ;;
  "issue view") [ -f "$GH_DIR/issue-$3.json" ] || exit 1; cat "$GH_DIR/issue-$3.json" ;;
  *) exit 1 ;;
esac
STUB
  chmod +x "$GH_DIR/bin/gh"
  export GH_DIR GH_LOG PATH="$GH_DIR/bin:$PATH"

  # Context files live on main, so a PR changing only src/ and wiki/ lists them
  # without having touched them.
  mkdir -p "$ALF_ROOT/.claude/rules" "$ALF_ROOT/apps/web/.claude/rules" "$ALF_ROOT/.claude/worktrees/x/.claude/rules"
  printf 'root\n' >"$ALF_ROOT/CLAUDE.md"
  printf 'web\n' >"$ALF_ROOT/apps/web/CLAUDE.md"
  printf 'always\n' >"$ALF_ROOT/.claude/rules/always.md"
  printf -- '---\npaths:\n  - "wiki/**/*"\n---\nbody\n' >"$ALF_ROOT/.claude/rules/wiki-only.md"
  printf -- '---\npaths:\n  - "src/**/*.sh"\n---\nbody\n' >"$ALF_ROOT/.claude/rules/shell-only.md"
  printf -- '---\npaths:\n  - "nowhere/**"\n---\nbody\n' >"$ALF_ROOT/.claude/rules/unmatched.md"
  printf 'web always\n' >"$ALF_ROOT/apps/web/.claude/rules/web-always.md"
  printf -- '---\npaths:\n  - "app/**/*"\n---\nbody\n' >"$ALF_ROOT/apps/web/.claude/rules/web-app.md"
  printf -- '---\npaths:\n  - "e2e/**"\n---\nbody\n' >"$ALF_ROOT/apps/web/.claude/rules/web-e2e.md"
  printf 'nested\n' >"$ALF_ROOT/.claude/worktrees/x/.claude/rules/nested.md"
  alf_git add -A
  alf_git add -f .claude/worktrees
  alf_git commit -q -m context
  alf_git push -q origin main 2>/dev/null
  alf_git fetch -q origin
  alf_branch feat/review
  alf_fill src/a.sh 3 script
  alf_fill wiki/b.md 3 page
  alf_commit "feature"
  # A rule file nobody tracked, and audit-run files that must stay out.
  printf 'untracked\n' >"$ALF_ROOT/.claude/rules/untracked.md"
  printf '[]\n' >"$ALF_ROOT/.gaia/local/audit/abc.findings.json"
  : >"$ALF_ROOT/.gaia/local/audit/abc.ok"
}

# set_pr <body>: the pull request `gh` reports, based on main.
set_pr() {
  jq -n -c --arg body "$1" '{baseRefName: "main", body: $body}' >"$GH_DIR/pr.json"
}

# set_issue <number> <association> <body>: an issue `gh issue view` reports.
set_issue() {
  jq -n -c --arg body "$3" --arg association "$2" '{body: $body, authorAssociation: $association}' >"$GH_DIR/issue-$1.json"
}

# build <out-name> [extra args...]: the bundle for PR 50 under the test's tmp dir.
build() {
  local name="$1"
  shift
  OUT="$BATS_TEST_TMPDIR/$name"
  run bash "$BUNDLE_SCRIPT" --root "$ALF_ROOT" --pr 50 --out "$OUT" "$@"
}

# listed <path>: whether rules.txt holds exactly that line.
listed() {
  grep -qxF -- "$1" "$OUT/rules.txt"
}

# open_record <name>: open a review record on the built bundle; sets RUN_FOLDER.
open_record() {
  RUN_FOLDER="$ALF_ROOT/.gaia/local/runs/$1"
  run bash "$SCRIPTS/pr-review-record.sh" open --root "$ALF_ROOT" --run-folder "$RUN_FOLDER" --pr 50 \
    --head "$(alf_git rev-parse HEAD)" --bundle "$OUT"
  [ "$status" -eq 0 ] || return 1
}

@test "a fork PR or an unanswerable fork query is refused before any other read" {
  local refusal='PR review: refused, PR #50 is from a fork or its origin is unknown'
  set_pr "Summary"

  # A fork: the exact line on stdout, exit 1, one gh call and no directory made.
  printf 'true\n' >"$GH_DIR/fork-answer"
  build fork
  [ "$status" -eq 1 ] || return 1
  [ "$output" = "$refusal" ] || return 1
  [ "$(wc -l <"$GH_LOG" | tr -d ' ')" -eq 1 ] || return 1
  grep -q 'isCrossRepository' "$GH_LOG" || return 1
  [ ! -e "$OUT" ] || return 1

  # gh cannot answer: the same refusal and still no other gh call.
  : >"$GH_LOG"
  GH_UNANSWERABLE=1 build unknown
  [ "$status" -eq 1 ] || return 1
  [ "$output" = "$refusal" ] || return 1
  [ "$(wc -l <"$GH_LOG" | tr -d ' ')" -eq 1 ] || return 1
  [ ! -e "$OUT" ] || return 1

  # A same-repository PR is not refused, and the fork question comes first.
  : >"$GH_LOG"
  printf 'false\n' >"$GH_DIR/fork-answer"
  build same
  [ "$status" -eq 0 ] || return 1
  [ "$(sed -n 1p "$GH_LOG" | grep -c isCrossRepository)" -eq 1 ] || return 1
}

@test "the bundle strips every audit heading, selects the rules for the changed paths, names nothing from the audit run, and marks a non-collaborator spec in the bundle and the record" {
  local heading body
  body="$(printf 'Summary line\n\nCloses #3743\n\n<!-- gaia-pr-body-head: abc123 -->\n<!-- gaia:pr-review:start -->')"
  # Every audit-written heading, derived from the one definition, each with a line under it.
  while IFS= read -r heading; do
    body="$(printf '%s\n\n%s\nunder-%s' "$body" "$heading" "$(printf '%s' "$heading" | tr -c '[:alnum:]\n' '_')")"
  done <<<"$(gaia_pr_body_audit_headings)"
  body="$(printf '%s\n\n## Kept section\nkept line' "$body")"
  set_pr "$body"
  set_issue 3743 NONE "Some request"

  build first
  [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; return 1; }

  # The body keeps the summary, the closing line and a non-audit section.
  grep -qxF 'Summary line' "$OUT/pr-body.md" || return 1
  grep -qxF 'Closes #3743' "$OUT/pr-body.md" || return 1
  grep -qxF 'kept line' "$OUT/pr-body.md" || return 1
  # None of the headings or their lines, including the Decided unattended block.
  [ "$(gaia_pr_body_audit_headings | wc -l | tr -d ' ')" -ge 10 ] || return 1
  grep -qF 'Decided unattended' <<<"$(gaia_pr_body_audit_headings)" || return 1
  while IFS= read -r heading; do
    grep -qxF -- "$heading" "$OUT/pr-body.md" && return 1
  done <<<"$(gaia_pr_body_audit_headings)"
  grep -q 'under-' "$OUT/pr-body.md" && return 1
  grep -q 'gaia-pr-body-head\|gaia:pr-review' "$OUT/pr-body.md" && return 1

  # Rules: the root CLAUDE.md, every rule with no paths key, each matching glob.
  listed CLAUDE.md || return 1
  listed .claude/rules/always.md || return 1
  listed .claude/rules/wiki-only.md || return 1
  listed .claude/rules/shell-only.md || return 1
  listed .claude/rules/unmatched.md && return 1
  listed .claude/rules/untracked.md && return 1
  listed .claude/worktrees/x/.claude/rules/nested.md && return 1
  listed apps/web/CLAUDE.md && return 1
  listed apps/web/.claude/rules/web-always.md && return 1
  grep -qxF src/a.sh "$OUT/changed-files.txt" || return 1
  grep -qxF wiki/b.md "$OUT/changed-files.txt" || return 1

  # Nothing from the audit run is named anywhere in the bundle.
  grep -rEq '\.gaia/local|dispositions-[^ ]*\.json|unit-[^ ]*\.json|\.findings\.json|\.ok([^[:alnum:]]|$)|\.refused' "$OUT" && return 1

  # A non-collaborator's issue is marked in the bundle and the record.
  grep -qxF '#3743' "$OUT/spec.md" || return 1
  grep -qxF 'spec author: not a collaborator' "$OUT/spec.md" || return 1
  [ "$(jq -r '.spec_author_not_collaborator' "$OUT/meta.json")" = true ] || return 1
  open_record flagged || return 1
  [ "$(jq -r '.spec_author_not_collaborator' "$RUN_FOLDER/pr-review.json")" = true ] || return 1
  set_issue 3743 MEMBER "Some request"
  build second
  [ "$status" -eq 0 ] || return 1
  grep -q 'not a collaborator' "$OUT/spec.md" && return 1
  [ "$(jq -r '.spec_author_not_collaborator' "$OUT/meta.json")" = false ] || return 1

  # A heading added to the one definition is stripped with no edit to the builder.
  local scratch="$BATS_TEST_TMPDIR/scratch-builder"
  mkdir -p "$scratch/.gaia/scripts" "$scratch/.claude/hooks"
  cp "$SCRIPTS/pr-review-bundle.sh" "$SCRIPTS/pr-review-bundle-lib.sh" "$scratch/.gaia/scripts/"
  cp -R "$REPO_ROOT/.claude/hooks/lib" "$scratch/.claude/hooks/lib"
  sed 's/^    "\$PR_BODY_HEADING_PR_REVIEW"$/    "$PR_BODY_HEADING_PR_REVIEW" \\\n    "## Brand new audit heading"/' \
    "$SCRIPTS/pr-body-sections-lib.sh" >"$scratch/.gaia/scripts/pr-body-sections-lib.sh"
  grep -qF 'Brand new audit heading' "$scratch/.gaia/scripts/pr-body-sections-lib.sh" || return 1
  set_pr "$(printf 'Summary line\n\n## Brand new audit heading\nnew-secret\n\n## Kept section\nkept line')"
  OUT="$BATS_TEST_TMPDIR/extended"
  run bash "$scratch/.gaia/scripts/pr-review-bundle.sh" --root "$ALF_ROOT" --pr 50 --out "$OUT"
  [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; return 1; }
  grep -q 'new-secret\|Brand new audit heading' "$OUT/pr-body.md" && return 1
  grep -qxF 'kept line' "$OUT/pr-body.md" || return 1

  # A bundle may not live where the reviewer cannot read.
  run bash "$BUNDLE_SCRIPT" --root "$ALF_ROOT" --pr 50 --out "$ALF_ROOT/.gaia/local/bundle"
  [ "$status" -eq 2 ] || return 1

  # A PR changing a path under apps/web also lists that directory's context files.
  alf_fill apps/web/app/x.tsx 2 component
  alf_commit "web change"
  set_pr "Summary"
  build web
  [ "$status" -eq 0 ] || return 1
  listed apps/web/CLAUDE.md || return 1
  listed apps/web/.claude/rules/web-always.md || return 1
  listed apps/web/.claude/rules/web-app.md || return 1
  listed apps/web/.claude/rules/web-e2e.md && return 1
  listed .claude/rules/always.md || return 1
  true
}

@test "the spec is chosen by precedence, and a PR with none carries spec none into the record and Coverage no spec into the section" {
  local spec_file="$BATS_TEST_TMPDIR/SPEC.md"
  printf -- '---\nid: SPEC-1\nsuccess_criteria:\n  - criterion one\n  - criterion two\nother: x\n---\n\n## Overview\noverview text\n\n## Behaviors\n- B1 behavior text\n\n## Notes\nnotes text\n' >"$spec_file"

  # --spec: the SPEC's criteria and behaviors plus the issue's Done-when.
  set_pr "Closes #3743"
  set_issue 3743 OWNER "$(printf 'intro text\n\n### Done when\n- done item\n\n### Later\nlater text')"
  build with-spec --spec "$spec_file"
  [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; return 1; }
  grep -qF 'criterion one' "$OUT/spec.md" || return 1
  grep -qF 'B1 behavior text' "$OUT/spec.md" || return 1
  grep -qF 'done item' "$OUT/spec.md" || return 1
  grep -qF 'overview text' "$OUT/spec.md" && return 1
  grep -qF 'notes text' "$OUT/spec.md" && return 1
  grep -qF 'intro text' "$OUT/spec.md" && return 1

  # No --spec, `Fixes #3743`, a `## Done when`: that section alone.
  set_pr "Fixes #3743"
  set_issue 3743 OWNER "$(printf 'intro text\n\n## Done when\n- done item\n\n## Later\nlater text')"
  build done-when
  [ "$status" -eq 0 ] || return 1
  grep -qxF '#3743' "$OUT/spec.md" || return 1
  grep -qF 'done item' "$OUT/spec.md" || return 1
  grep -qF 'intro text' "$OUT/spec.md" && return 1
  grep -qF 'later text' "$OUT/spec.md" && return 1
  [ "$(jq -r '.spec' "$OUT/meta.json")" = present ] || return 1

  # No Done-when: the issue body whole.
  set_issue 3743 OWNER "$(printf 'whole body line\nsecond line')"
  build whole-body
  [ "$status" -eq 0 ] || return 1
  grep -qF 'whole body line' "$OUT/spec.md" || return 1
  grep -qF 'second line' "$OUT/spec.md" || return 1

  # Two closing keywords: each issue's text under its own label.
  set_pr "$(printf 'Closes #3743 and resolves #3744')"
  set_issue 3743 OWNER "$(printf '## Done when\nfirst done')"
  set_issue 3744 OWNER "$(printf '## Done when\nsecond done')"
  build two-issues
  [ "$status" -eq 0 ] || return 1
  [ "$(grep -n '^#374[34]$' "$OUT/spec.md" | cut -d: -f2 | tr '\n' ' ')" = '#3743 #3744 ' ] || return 1
  [ "$(awk '/^#3743$/{f=1;next} /^#3744$/{f=0} f' "$OUT/spec.md" | grep -c 'first done')" -eq 1 ] || return 1
  [ "$(awk '/^#3744$/{f=1;next} f' "$OUT/spec.md" | grep -c 'second done')" -eq 1 ] || return 1

  # Heading levels: `#### done when` is read; `# Done when` and `##### Done when` are not.
  set_pr "Closes #3743"
  set_issue 3743 OWNER "$(printf 'lead line\n#### done when\nlevel four item\n')"
  build level-four
  [ "$status" -eq 0 ] || return 1
  grep -qF 'level four item' "$OUT/spec.md" || return 1
  grep -qF 'lead line' "$OUT/spec.md" && return 1
  set_issue 3743 OWNER "$(printf 'lead line\n# Done when\nlevel one item\n')"
  build level-one
  [ "$status" -eq 0 ] || return 1
  grep -qF 'lead line' "$OUT/spec.md" || return 1
  set_issue 3743 OWNER "$(printf 'lead line\n##### Done when\nlevel five item\n')"
  build level-five
  [ "$status" -eq 0 ] || return 1
  grep -qF 'lead line' "$OUT/spec.md" || return 1

  # A gh failure reading a closed issue fails the build, never a silent none.
  set_pr "Closes #9999"
  build unreadable-issue
  [ "$status" -eq 2 ] || return 1
  [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" -eq 1 ] || return 1

  # No closed issue and no --spec: spec none in the bundle, the record and the section.
  set_pr "Just a summary, mentions #3743 without a closing keyword"
  build no-spec
  [ "$status" -eq 0 ] || return 1
  [ "$(cat "$OUT/spec.md")" = 'spec: none' ] || return 1
  [ "$(jq -r '.spec' "$OUT/meta.json")" = none ] || return 1
  open_record none || return 1
  [ "$(jq -r '.spec' "$RUN_FOLDER/pr-review.json")" = none ] || return 1
  run bash "$SCRIPTS/pr-review-gate.sh" section --run-folder "$RUN_FOLDER"
  [ "$status" -eq 0 ] || return 1
  grep -qxF 'Coverage: no spec.' <<<"$output" || return 1
}

@test "an absent CHANGELOG or PR template is named absent" {
  set_pr "Summary"
  build absent
  [ "$status" -eq 0 ] || return 1
  grep -qxF 'CHANGELOG.md: absent' "$OUT/bundle.md" || return 1
  grep -qxF 'PR template: absent' "$OUT/bundle.md" || return 1
  [ "$(jq -c '[.changelog_present, .template_present]' "$OUT/meta.json")" = '[false,false]' ] || return 1

  # Present ones are named, the first template location winning.
  printf '# Changelog\n' >"$ALF_ROOT/CHANGELOG.md"
  mkdir -p "$ALF_ROOT/.github" "$ALF_ROOT/docs"
  printf 't\n' >"$ALF_ROOT/docs/pull_request_template.md"
  printf 't\n' >"$ALF_ROOT/.github/pull_request_template.md"
  alf_commit "docs"
  build present
  [ "$status" -eq 0 ] || return 1
  grep -qxF 'CHANGELOG.md: present' "$OUT/bundle.md" || return 1
  grep -qxF 'PR template: .github/pull_request_template.md' "$OUT/bundle.md" || return 1
  [ "$(jq -c '[.changelog_present, .template_present]' "$OUT/meta.json")" = '[true,true]' ] || return 1
}
