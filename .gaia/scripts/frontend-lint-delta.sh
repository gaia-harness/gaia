#!/usr/bin/env bash
# Lints the frontend files the tests workflow's `Vitest and Playwright` job
# changed since its last green base, rather than the whole app: the commit-time
# Quality Gate already lints staged files, so CI is the backstop for commits
# that skipped it, and a whole-tree lint is slow at scale.
#
# Usage: frontend-lint-delta.sh --root <dir> --base <ref> [--plan]
#
# --base is the last-green base the job resolved (.github/audit/resolve-check-base.sh).
# --plan prints the decision instead of linting: `full`, `none`, or `delta`
# followed by one changed path per line, relative to frontend/.
#
# A change to a lint input (the ESLint or Prettier config, a tsconfig the
# type-aware rules read, or a manifest or lockfile that can move a lint plugin)
# can turn an untouched file red, so it lints everything instead.
# --no-renames lists a moved file's new path, and its importers must change
# their import path, so an architecture-boundaries violation from a move is in
# the delta too. --diff-filter=d drops deleted paths, which ESLint cannot open.
# --no-warn-ignored keeps an explicitly passed ignored file (the msw worker
# script) from tripping --max-warnings=0.
#
# Exit: 0 when the lint passes or nothing is lintable, 1 on a lint failure, 2
# on a usage error or a diff that cannot be read (never read as "no change").

set -euo pipefail

root=""
base=""
plan=false
while [ "$#" -gt 0 ]; do
  case "$1" in
    --root | --base)
      [ "$#" -ge 2 ] || { echo "frontend-lint-delta: $1 needs a value" >&2; exit 2; }
      case "$1" in
        --root) root="$2" ;;
        --base) base="$2" ;;
      esac
      shift 2
      ;;
    --plan)
      plan=true
      shift
      ;;
    *)
      echo "frontend-lint-delta: unknown argument: $1" >&2
      exit 2
      ;;
  esac
done

if [ -z "$root" ] || [ ! -d "$root" ]; then
  echo "frontend-lint-delta: --root must name an existing directory" >&2
  exit 2
fi
[ -n "$base" ] || { echo "frontend-lint-delta: --base is required" >&2; exit 2; }

delta_file="$(mktemp)"
trap 'rm -f "$delta_file"' EXIT

if ! git -C "$root" diff --name-only -z --no-renames --diff-filter=d "${base}...HEAD" > "$delta_file"; then
  echo "frontend-lint-delta: could not read the diff from ${base}" >&2
  exit 2
fi

lint_input_pattern='^frontend/(eslint|prettier)\.config\.|^frontend/tsconfig[^/]*\.json$|^frontend/package\.json$|^(package\.json|pnpm-lock\.yaml|pnpm-workspace\.yaml)$'
# A here-string, not a pipe into `grep -q`: under pipefail an early-exiting
# reader can SIGPIPE the writer and turn a match into a false miss.
delta_lines="$(tr '\0' '\n' < "$delta_file")"
if grep -qE "$lint_input_pattern" <<<"$delta_lines"; then
  if [ "$plan" = true ]; then
    echo full
    exit 0
  fi
  echo "frontend-lint-delta: a lint input changed, linting every frontend file"
  exec pnpm -C "$root/frontend" lint-dry
fi

lint_paths=()
while IFS= read -r -d '' path; do
  case "$path" in
    frontend/*.js | frontend/*.jsx | frontend/*.ts | frontend/*.tsx | frontend/*.mjs | frontend/*.cjs)
      lint_paths+=("${path#frontend/}") ;;
  esac
done < "$delta_file"

if [ "${#lint_paths[@]}" -eq 0 ]; then
  if [ "$plan" = true ]; then
    echo none
  else
    echo "frontend-lint-delta: no lintable frontend file changed since ${base}"
  fi
  exit 0
fi

if [ "$plan" = true ]; then
  echo delta
  printf '%s\n' "${lint_paths[@]}"
  exit 0
fi

echo "frontend-lint-delta: linting ${#lint_paths[@]} changed file(s)"
exec pnpm -C "$root/frontend" exec eslint --fix-dry-run --max-warnings=0 --no-warn-ignored -- "${lint_paths[@]}"
