#!/usr/bin/env bash
# Fixture builder for the audit scope's release-bookkeeping arm, shared by the
# classifier suite and the merge-gate suite so both classify the same change.
#
# The base holds GAIA's release bookkeeping files at 1.0.0 plus one source
# file; the release commit graduates them to 1.1.0 the way /gaia-release does,
# leaving the two optional wiki files alone (a release with no wiki drift).
# The shapes match .gaia/scripts/tests/release-bookkeeping-check.bats, which
# owns the predicate's own cases; this file only needs one change it accepts.
#
# Sourced, never executed. Every git call is `git -C <root>`; never `cd`.

_release_bookkeeping_write() {
  mkdir -p "$(dirname "$1/$2")"
  printf '%s' "$3" > "$1/$2"
}

_release_bookkeeping_package() {
  printf '{\n  "name": "%s",\n  "version": "%s",\n  "private": true\n}\n' "$1" "$2"
}

_release_bookkeeping_manifest() {
  printf '{\n  "files": {\n    "a.sh": "owned"\n  },\n  "generated": "%s",\n  "version": "%s"\n}\n' "$1" "$2"
}

# _release_bookkeeping_changelog <unreleased-compare-version> [<graduated-version>]
_release_bookkeeping_changelog() {
  printf '# Changelog\n\n## [Unreleased]\n\n'
  [ -z "${2:-}" ] || printf '## [%s] - 2026-10-29\n\n' "$2"
  printf '### Added\n\n- **Thing:** it works (#1)\n\n## [1.0.0] - 2026-10-01\n\n- First.\n\n'
  printf '[Unreleased]: https://github.com/example/repo/compare/v%s...HEAD\n' "$1"
  [ -z "${2:-}" ] || printf '[%s]: https://github.com/example/repo/releases/tag/v%s\n' "$2" "$2"
  printf '[1.0.0]: https://github.com/example/repo/releases/tag/v1.0.0\n'
}

# release_bookkeeping_seed_base <root>: writes the 1.0.0 bookkeeping files and
# a.sh into the working tree and commits them on the current branch.
release_bookkeeping_seed_base() {
  local root="$1"
  _release_bookkeeping_write "$root" .gaia/VERSION $'1.0.0\n'
  _release_bookkeeping_write "$root" .gaia/manifest.json "$(_release_bookkeeping_manifest 2026-10-01T00:00:00.000Z 1.0.0)"
  _release_bookkeeping_write "$root" package.json "$(_release_bookkeeping_package gaia 1.0.0)"
  _release_bookkeeping_write "$root" frontend/package.json "$(_release_bookkeeping_package frontend 1.0.0)"
  _release_bookkeeping_write "$root" CHANGELOG.md "$(_release_bookkeeping_changelog 1.0.0)"
  _release_bookkeeping_write "$root" a.sh $'echo hi\n'
  git -C "$root" add .gaia/VERSION .gaia/manifest.json package.json frontend/package.json CHANGELOG.md a.sh
  git -C "$root" commit -q -m "release-bookkeeping base"
}

# release_bookkeeping_apply <root> [extra]: one release commit on the current
# branch. `extra` also edits a.sh, the change the predicate must reject.
release_bookkeeping_apply() {
  local root="$1" variant="${2:-}"
  _release_bookkeeping_write "$root" .gaia/VERSION $'1.1.0\n'
  _release_bookkeeping_write "$root" .gaia/manifest.json "$(_release_bookkeeping_manifest 2026-10-29T00:00:00.000Z 1.1.0)"
  _release_bookkeeping_write "$root" package.json "$(_release_bookkeeping_package gaia 1.1.0)"
  _release_bookkeeping_write "$root" frontend/package.json "$(_release_bookkeeping_package frontend 1.1.0)"
  _release_bookkeeping_write "$root" CHANGELOG.md "$(_release_bookkeeping_changelog 1.1.0 1.1.0)"
  [ "$variant" != extra ] || _release_bookkeeping_write "$root" a.sh $'echo changed\n'
  git -C "$root" add -A .gaia/VERSION .gaia/manifest.json package.json frontend/package.json CHANGELOG.md a.sh
  git -C "$root" commit -q -m "chore(release): v1.1.0"
}

# release_bookkeeping_install_predicate <root>: copies the real predicate into
# <root>, untracked, where the audit scope looks for it.
release_bookkeeping_install_predicate() {
  local root="$1" repository_root
  repository_root="$(cd "${BASH_SOURCE[0]%/*}/../../.." && pwd)"
  mkdir -p "$root/.gaia/scripts"
  cp "$repository_root/.gaia/scripts/release-bookkeeping-check.sh" "$root/.gaia/scripts/release-bookkeeping-check.sh"
  chmod +x "$root/.gaia/scripts/release-bookkeeping-check.sh"
}
