#!/usr/bin/env bats
#
# Static contract for the frontend image (SPEC-092 Docker contract, SEC-004,
# CG-014). The real build and the "image serves home, no environment file
# inside" run belong to the verification phase; this suite pins the files that
# make them possible.
#
#   - apps/web/Dockerfile builds from the repo root, installs from the root
#     lockfile, deploys the frontend package, and keeps `pnpm start`.
#   - apps/web/Dockerfile.dockerignore keeps every dotenv file out of the
#     context. The ignore rules are evaluated with git's matcher
#     (`git check-ignore --no-index` over a temp repo whose .gitignore is a
#     copy of the patterns). That approximates Docker's matcher, and is exact
#     for the `**/` and literal patterns the dotenv checks depend on.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"
  DOCKERFILE="$REPO_ROOT/apps/web/Dockerfile"
  IGNORE_FILE="$REPO_ROOT/apps/web/Dockerfile.dockerignore"
  DOTENV=".env"
  DOTENV_STAR=".env.*"
}

# Exit 0 when git would ignore path $2 under the ignore patterns in file $1.
ignored_by_patterns() {
  local patterns="$1" path="$2" repo
  repo="$(mktemp -d "$BATS_TEST_TMPDIR/ignore-repo.XXXXXX")"
  git -C "$repo" init -q
  cp "$patterns" "$repo/.gitignore"
  git -C "$repo" check-ignore --no-index -q -- "$path"
}

# Dockerfile text with comment lines dropped.
dockerfile_instructions() {
  grep -vE '^[[:space:]]*#' "$DOCKERFILE"
}

# Succeeds when stdin holds a COPY of the whole context (a bare `.` source).
copies_whole_context() {
  grep -qE '^COPY (--[a-z]+=[^ ]+ )*\. '
}

@test "Dockerfile deploys the web package from the root frozen install, ends with CMD pnpm start in /app, never copies the whole context into the final stage, never runs corepack, and installs pnpm only after the sha512 check" {
  local instructions last_cmd last_workdir last_line final_stage before_install
  instructions="$(dockerfile_instructions)"
  [[ "$instructions" == *"pnpm deploy --filter web"* ]] || { echo "no pnpm deploy --filter web"; return 1; }
  [[ "$instructions" == *"pnpm-lock.yaml"* ]] || { echo "no pnpm-lock.yaml copy"; return 1; }
  [[ "$instructions" == *"pnpm-workspace.yaml"* ]] || { echo "no pnpm-workspace.yaml copy"; return 1; }
  [[ "$instructions" == *"pnpm install --frozen-lockfile"* ]] || { echo "no frozen install"; return 1; }

  last_line="$(printf '%s\n' "$instructions" | grep -vE '^[[:space:]]*$' | tail -n 1)"
  [ "$last_line" = 'CMD ["pnpm", "start"]' ] || { echo "last line: $last_line"; return 1; }
  last_cmd="$(printf '%s\n' "$instructions" | grep -E '^CMD ' | tail -n 1)"
  [ "$last_cmd" = 'CMD ["pnpm", "start"]' ] || { echo "last CMD: $last_cmd"; return 1; }
  last_workdir="$(printf '%s\n' "$instructions" | grep -E '^WORKDIR ' | tail -n 1)"
  [ "$last_workdir" = "WORKDIR /app" ] || { echo "last WORKDIR: $last_workdir"; return 1; }

  final_stage="$(printf '%s\n' "$instructions" | awk '/^FROM /{buf=""} {buf = buf $0 "\n"} END{printf "%s", buf}')"
  [[ "$final_stage" == "FROM "* ]] || { echo "final stage does not start at FROM"; return 1; }
  copies_whole_context <<<"$final_stage" && { echo "final stage copies the whole context"; return 1; }

  grep -qi 'corepack' <<<"$instructions" && { echo "Dockerfile runs corepack"; return 1; }

  [[ "$instructions" == *'npm install -g "./pnpm-'* ]] || { echo "no npm install -g of the pinned pnpm"; return 1; }
  before_install="${instructions%%npm install -g \"./pnpm-*}"
  [[ "$before_install" == *'packageManager'* ]] || { echo "no packageManager read before the install"; return 1; }
  [[ "$before_install" == *'npm pack'* ]] || { echo "no npm pack before the install"; return 1; }
  [[ "$before_install" == *'sha512sum -c'* ]] || { echo "no sha512sum -c before the install"; return 1; }
}

# bats test_tags=protected
@test "dockerignore keeps every dotenv file out of the context but includes apps/web/app/root.tsx, and lists the dotenv patterns literally" {
  local row path expected
  for row in "$DOTENV|0" "apps/web/$DOTENV|0" "apps/web/${DOTENV}.local|0" "apps/web/app/root.tsx|1"; do
    path=${row%|*}; expected=${row##*|}
    run ignored_by_patterns "$IGNORE_FILE" "$path"
    [ "$status" -eq "$expected" ] || { echo "row $row: status $status"; return 1; }
  done
  run grep -Fxc "**/$DOTENV" "$IGNORE_FILE"
  [ "$output" -ge 1 ] || { echo "no literal **/$DOTENV line"; return 1; }
  run grep -Fxc "**/$DOTENV_STAR" "$IGNORE_FILE"
  [ "$output" -ge 1 ]
}

# bats test_tags=whole-tree
@test "no root Dockerfile or .dockerignore remains tracked" {
  local tracked=0 path
  while IFS= read -r -d '' path; do
    tracked=$((tracked + 1))
  done < <(git -C "$REPO_ROOT" ls-files -z -- .dockerignore Dockerfile)
  [ "$tracked" -eq 0 ]
}

# Prints the "version" value of package manifest $1, empty when absent.
manifest_version() {
  sed -nE 's/^[[:space:]]*"version"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/p' "$1" | head -n 1
}

# The app reads npm_package_version, which pnpm sets only from the running
# package's own manifest, so the frontend manifest must carry the root version.
@test "apps/web/package.json carries a non-empty version equal to the root version" {
  local root_version frontend_version
  root_version="$(manifest_version "$REPO_ROOT/package.json")"
  frontend_version="$(manifest_version "$REPO_ROOT/apps/web/package.json")"
  [ -n "$root_version" ]
  [ -n "$frontend_version" ]
  [ "$frontend_version" = "$root_version" ]
}
