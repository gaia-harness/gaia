#!/usr/bin/env bash
# Build a local GAIA bundle tarball from an unreleased, committed checkout, for
# `/update-gaia --local <tarball>` in an adopter project.
#
# Usage: build-local-bundle.sh <output-dir>
#
# Prints `TAG v<core>-dev.<sha>` and `BUNDLE <absolute tarball path>`, and
# writes `gaia-bundle-<tag>.tar.gz` plus its `.sha256` (release format) into
# <output-dir>. The tarball has the release shape (one top-level directory, the
# staged and scrubbed tree) plus `.gaia/VERSION-dev` holding `dev.<sha>`, so the
# bundle is identified by the commit it was built from. `.gaia/VERSION` stays a
# plain x.y.z.
#
# Maintainer-only and release-excluded with the rest of `.gaia/tests`.
#
# Steps, in order: refuse uncommitted tracked changes; run the committed-CLI
# freshness check; stage through build-staging.sh; regenerate the manifest into
# the staged tree only; write `.gaia/VERSION-dev`; re-run scrub and runtime-deps
# on the final tree; tar and checksum. `.gaia/VERSION-dev` is written after the
# scrub and manifest steps because the release pipeline must never see it, and
# the final re-run proves the adopter-facing tree is still clean with it present.
set -euo pipefail

if [ "$#" -ne 1 ]; then
  printf 'Usage: %s <output-dir>\n' "$0" >&2
  exit 1
fi

# A relative output directory resolves against the caller's cwd, before any cd.
mkdir -p "$1"
OUTPUT_DIRECTORY="$(cd "$1" && pwd)"
SOURCE_ROOT="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
MAINTAINER_CLI="$SOURCE_ROOT/.gaia/cli/gaia-maintainer"
# Overridable so the suite can run the builder in a scratch clone that has no
# node_modules to rebuild the CLI with.
FRESHNESS_CHECK="${GAIA_LOCAL_BUNDLE_FRESHNESS_CHECK:-$SOURCE_ROOT/.gaia/scripts/verify-cli-bundle-fresh.sh}"

# Every source-side step runs from the source root: `release scrub` resolves
# its config files against the process cwd.
if [ -n "$(git -C "$SOURCE_ROOT" status --porcelain --untracked-files=no)" ]; then
  printf 'Refusing: the source tree has uncommitted tracked changes; commit first, any branch is fine.\n' >&2
  exit 1
fi

if ! (cd "$SOURCE_ROOT" && bash "$FRESHNESS_CHECK") >&2; then
  printf 'Refusing: the committed CLI bundles are stale; rebuild them with pnpm -C .gaia/cli bundle and commit.\n' >&2
  exit 1
fi

CORE_VERSION="$(tr -d '[:space:]' < "$SOURCE_ROOT/.gaia/VERSION")"
SHORT_SHA="$(git -C "$SOURCE_ROOT" rev-parse --short=12 HEAD)"
TAG="v${CORE_VERSION}-dev.${SHORT_SHA}"
TARBALL_NAME="gaia-bundle-${TAG}.tar.gz"

if [ -e "$OUTPUT_DIRECTORY/$TARBALL_NAME" ]; then
  printf 'Refusing: %s already exists; remove it or pick another output directory.\n' "$OUTPUT_DIRECTORY/$TARBALL_NAME" >&2
  exit 1
fi

SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/gaia-local-bundle-XXXXXX")"
trap 'rm -rf "$SCRATCH"' EXIT
STAGED="$SCRATCH/gaia-${TAG}"
mkdir "$STAGED"

(cd "$SOURCE_ROOT" && bash "$SOURCE_ROOT/.gaia/tests/distribution/lib/build-staging.sh" "$STAGED")

# The committed manifest is stale on any branch that added shipped files since
# the last release, so regenerate into the staged tree; stdout never writes the
# source repository.
(cd "$SOURCE_ROOT" && "$MAINTAINER_CLI" release manifest --stdout --allow-undecided) > "$STAGED/.gaia/manifest.json"

printf 'dev.%s\n' "$SHORT_SHA" > "$STAGED/.gaia/VERSION-dev"

(cd "$SOURCE_ROOT" && "$MAINTAINER_CLI" release scrub "$STAGED")
(cd "$SOURCE_ROOT" && "$MAINTAINER_CLI" release runtime-deps --staging "$STAGED")

tar -czf "$SCRATCH/$TARBALL_NAME" -C "$SCRATCH" "gaia-${TAG}"
mv "$SCRATCH/$TARBALL_NAME" "$OUTPUT_DIRECTORY/$TARBALL_NAME"
(cd "$OUTPUT_DIRECTORY" && shasum -a 256 "$TARBALL_NAME" > "$TARBALL_NAME.sha256")

printf 'TAG %s\n' "$TAG"
printf 'BUNDLE %s\n' "$OUTPUT_DIRECTORY/$TARBALL_NAME"
