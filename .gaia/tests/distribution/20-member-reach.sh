#!/usr/bin/env bash
# 20-member-reach.sh
#
# What the staged bundle's own machinery reaches in a crossed monorepo: every
# member registered, a library with empty globs and only a typecheck script,
# infra with a Terraform file beside a shell script. The crossing verbs build
# the fixture from the staged binary.
#
#   1. A real commit through the staged pre-commit hook runs each owner's
#      checks: a library type error fails the commit and passes once fixed
#      (the library's missing scripts are skipped), a change under the web
#      member runs the web member's typecheck, and a Terraform file with a shell
#      script plans no member at all.
#   2. The dispatch resolver names the default and shell members for the infra
#      diff.
#   3. The scope command, taken literally from the frontend agent file, names
#      web lenses for web paths, none for the library or infra, and security for
#      every path including the Terraform and shell files.
#
# Layer 0.5: runs on the host or runner, no Docker, no pnpm install.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib/lib.sh"
source "$HERE/lib/data-layer.sh"
source "$HERE/lib/crossed-fixture.sh"
source "$HERE/lib/workspace-proof.sh"

require_command jq "jq is required to read the registry"
require_command rsync "rsync required for adopter-flow scaffold copy"
require_command pnpm "pnpm required to run the members' scripts"

stage_adopter_tree member-reach
TOOL_BIN="$(proof_tool_bin)" || exit 1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
export CROSSED_FIXTURE_GAIA="$GAIA"

FIXTURE="$WORK/monorepo"
crossed_fixture_build "$FIXTURE" \
  || { fail "the crossed fixture could not be built from the staged binary"; exit 1; }
proof_install_machinery "$STAGING" "$FIXTURE"

# The library: no globs, only typecheck. The web member records that its
# typecheck ran.
jq '. + {scripts: {typecheck: "tsc --noEmit -p ."}}' "$FIXTURE/packages/kit/package.json" >"$WORK/kit-package.json"
cp "$WORK/kit-package.json" "$FIXTURE/packages/kit/package.json"
printf '{"compilerOptions":{"strict":true,"noEmit":true,"target":"es2022","module":"esnext","moduleResolution":"bundler"},"include":["src"]}\n' \
  >"$FIXTURE/packages/kit/tsconfig.json"
jq '. + {scripts: {typecheck: "echo web >> ../../.typecheck-ran"}}' "$FIXTURE/apps/web/package.json" >"$WORK/web-package.json"
cp "$WORK/web-package.json" "$FIXTURE/apps/web/package.json"
printf '.typecheck-ran\n' >>"$FIXTURE/.gitignore"

# Infra: a Terraform file beside a shell script, under the default member's
# infra claim the crossing wrote. The shell member joins the roster as the
# shipped roster declares it.
mkdir -p "$FIXTURE/apps/web/app"
awk '/^unowned:/ { print "  - name: code-audit-shell\n    globs:\n      - \"**/*.sh\"\n    audience: adopter" } { print }' \
  "$FIXTURE/.gaia/audit-ci.yml" >"$WORK/audit-ci.yml"
cp "$WORK/audit-ci.yml" "$FIXTURE/.gaia/audit-ci.yml"
_crossed_fixture_commit "$FIXTURE" 'members'

ORIGIN="$WORK/origin.git"
git init -q --bare -b main "$ORIGIN"
git -C "$FIXTURE" remote add origin "$ORIGIN"
git -C "$FIXTURE" push -q origin main
git -C "$FIXTURE" fetch -q origin
git -C "$FIXTURE" checkout -q -b feature
proof_enable_hooks "$FIXTURE" "$WORK/hooks"

# commit_staged MESSAGE: commits through the hook; sets COMMIT_STATUS and the
# hook's output in $WORK/commit.log.
commit_staged() {
  COMMIT_STATUS=0
  (cd "$FIXTURE" && PATH="$TOOL_BIN:$PATH" git commit -q -m "$1") >"$WORK/commit.log" 2>&1 || COMMIT_STATUS=$?
}

# --- 1. The commit gate ------------------------------------------------------

mkdir -p "$FIXTURE/infra"
printf 'resource "example" "main" {}\n' >"$FIXTURE/infra/main.tf"
printf '#!/usr/bin/env bash\necho ok\n' >"$FIXTURE/infra/run.sh"
git -C "$FIXTURE" add infra/main.tf infra/run.sh
commit_staged 'infra: add terraform and a script'
[ "$COMMIT_STATUS" -eq 0 ] \
  || { cat "$WORK/commit.log" >&2; fail "a Terraform file beside a shell script was refused by the hook"; exit 1; }
[ ! -e "$FIXTURE/.typecheck-ran" ] \
  || { fail "an infra-only commit ran the web member's typecheck"; exit 1; }

DISPATCHED="$(bash "$FIXTURE/.gaia/scripts/resolve-audit-members.sh" --root "$FIXTURE" --base origin/main)" \
  || { fail "the dispatch resolver failed on the infra diff"; exit 1; }
[ "$DISPATCHED" = "$(printf 'code-audit-frontend\ncode-audit-shell')" ] \
  || { fail "the infra diff dispatched: $(printf '%s' "$DISPATCHED" | tr '\n' ' ')"; exit 1; }

printf "export const value: number = 'text';\n" >"$FIXTURE/packages/kit/src/index.ts"
git -C "$FIXTURE" add packages/kit/src/index.ts
commit_staged 'kit: break a type'
[ "$COMMIT_STATUS" -ne 0 ] \
  || { fail "a library type error did not fail the commit"; exit 1; }
grep -q 'TS2322' "$WORK/commit.log" \
  || { cat "$WORK/commit.log" >&2; fail "the refused commit does not show the library's type error"; exit 1; }

printf 'export const value: number = 2;\n' >"$FIXTURE/packages/kit/src/index.ts"
git -C "$FIXTURE" add packages/kit/src/index.ts
commit_staged 'kit: fix the type'
[ "$COMMIT_STATUS" -eq 0 ] \
  || { cat "$WORK/commit.log" >&2; fail "the fixed library commit was refused (its missing scripts must be skipped)"; exit 1; }

printf 'export const Panel = () => t("hello");\n' >"$FIXTURE/apps/web/app/panel.tsx"
git -C "$FIXTURE" add apps/web/app/panel.tsx
commit_staged 'web: add a panel'
[ "$COMMIT_STATUS" -eq 0 ] \
  || { cat "$WORK/commit.log" >&2; fail "a web member commit was refused"; exit 1; }
[ "$(cat "$FIXTURE/.typecheck-ran" 2>/dev/null)" = web ] \
  || { fail "the web member's typecheck did not run exactly once for the web commit"; exit 1; }
log "commit gate: library failure and fix, web check, infra plans nothing: OK"

# --- 3. Scope lenses from the agent file's own command -----------------------

SCOPE_COMMAND="$(grep -m1 '^<root>/\.gaia/scripts/audit-resolve-scope\.sh ' "$STAGING/.claude/agents/code-audit-frontend.md")"
[ -n "$SCOPE_COMMAND" ] \
  || { fail "the frontend agent file carries no literal scope command"; exit 1; }
SCOPE_COMMAND="${SCOPE_COMMAND//<root>/$FIXTURE}"
SCOPE_OUTPUT="$(cd "$FIXTURE" && bash -c "$SCOPE_COMMAND" </dev/null 2>"$WORK/scope.err")" \
  || { cat "$WORK/scope.err" >&2; fail "the agent file's scope command failed on the fixture"; exit 1; }

WEB_LENSES='react-patterns,translation,accessibility,project-specific-rules,security'
has_scope_line() {
  grep -qxF -- "$1" <<<"$SCOPE_OUTPUT" \
    || { printf '%s\n' "$SCOPE_OUTPUT" >&2; fail "the scope output lacks: $1"; exit 1; }
}
has_scope_line "LENSES=apps/web/app/panel.tsx"$'\t'"$WEB_LENSES"
has_scope_line "LENSES=packages/kit/src/index.ts"$'\t'security
has_scope_line "LENSES=infra/main.tf"$'\t'security
has_scope_line "LENSES=infra/run.sh"$'\t'security
scope_line_has_web_lenses() {
  awk -v path="$1" 'index($0, "LENSES=") && index($0, path) && index($0, "react-patterns") { found = 1 }
    END { exit !found }' <<<"$SCOPE_OUTPUT"
}
if scope_line_has_web_lenses 'packages/kit'; then
  fail "the library path took web lenses"; exit 1
fi
if scope_line_has_web_lenses 'infra/'; then
  fail "an infra path took web lenses"; exit 1
fi

pass "member reach: hook checks per owner, resolver members and web-only lenses hold on the crossed fixture"
