#!/usr/bin/env bash
# Fixture builder for the classifier's release-change skip, shared by the
# classifier, digest, resolver, scope-resolver and merge-gate suites so every
# one of them classifies the same tree.
#
# The roster carries four members:
#   fixture-default   default, globs `**`
#   fixture-shell     keyed `skip_gaia_release_changes: true`; shell globs
#   fixture-scripts   unkeyed claimant AFTER the keyed one, overlapping it on
#                     `.gaia/scripts/**`, so a skipped path falls through to it
#   fixture-idle      owns a prefix no branch touches; its digest frame holds
#                     only machinery, which makes it the reference a test
#                     compares other members' digests against
#
# The base commit ships VERSION 1.0.0 and a manifest marking the GAIA files
# `owned`. Each branch kind below is one commit on top of that base.
#
# Sourced, never executed. Every git call is `git -C <root>`; never `cd`.

# release_skip_roster <file> [without-keyed]: writes the fixture roster; the
# second argument drops the keyed member, the "keyed entry removed" control.
release_skip_roster() {
  local file="$1" variant="${2:-}"
  mkdir -p "$(dirname "$file")"
  {
    printf '%s\n' 'auditors:' \
      '  - name: fixture-default' \
      '    globs:' \
      '      - "**"' \
      '    default: true'
    if [ "$variant" != without-keyed ]; then
      printf '%s\n' '  - name: fixture-shell' \
        '    globs:' \
        '      - "**/*.sh"' \
        '      - "**/*.bats"' \
        '      - ".claude/hooks/**"' \
        '    skip_gaia_release_changes: true'
    fi
    printf '%s\n' '  - name: fixture-scripts' \
      '    globs:' \
      '      - ".gaia/scripts/**"' \
      '  - name: fixture-idle' \
      '    globs:' \
      '      - ".idle/**"'
  } > "$file"
}

# _release_skip_manifest <file> <owned-path>...: a manifest marking each path
# owned, plus one `shared` entry that must never join the owned set.
_release_skip_manifest() {
  local file="$1" path
  shift
  {
    printf '{\n  "files": {\n    "CLAUDE.md": "shared"'
    for path in "$@"; do
      printf ',\n    "%s": "owned"' "$path"
    done
    printf '\n  }\n}\n'
  } > "$file"
}

_release_skip_write() {
  mkdir -p "$(dirname "$1/$2")"
  printf '%s\n' "$3" > "$1/$2"
}

# release_skip_seed_base <root>: commits the base state on the current branch
# of an existing repository.
release_skip_seed_base() {
  local root="$1"
  release_skip_roster "$root/.gaia/audit-ci.yml"
  _release_skip_write "$root" .gaia/VERSION 1.0.0
  _release_skip_manifest "$root/.gaia/manifest.json" \
    .gaia/scripts/gaia-tool.sh .claude/hooks/gaia-guard.sh \
    .gaia/scripts/gaia-retired.sh .github/audit/gaia-audit.sh
  _release_skip_write "$root" .gaia/scripts/gaia-tool.sh '#!/usr/bin/env bash'
  _release_skip_write "$root" .claude/hooks/gaia-guard.sh '#!/usr/bin/env bash'
  _release_skip_write "$root" .gaia/scripts/gaia-retired.sh '#!/usr/bin/env bash'
  _release_skip_write "$root" .github/audit/gaia-audit.sh '#!/usr/bin/env bash'
  _release_skip_write "$root" CLAUDE.md '# project'
  git -C "$root" add -A
  git -C "$root" commit -q -m "release-skip base"
}

# release_skip_init <root>: a fresh repository on main holding the base state.
release_skip_init() {
  local root="$1"
  mkdir -p "$root"
  git -C "$root" init -q --initial-branch=main
  git -C "$root" config user.email test@example.com
  git -C "$root" config user.name Test
  git -C "$root" config commit.gpgsign false
  release_skip_seed_base "$root"
}

_release_skip_bump_version() {
  _release_skip_write "$1" .gaia/VERSION 1.1.0
}

# release_skip_apply <root> <kind>: one commit of the named branch kind on the
# checked-out branch.
#   release            VERSION bump; edits two owned scripts and an owned
#                      .github/audit script; adds one owned only in the head
#                      manifest; deletes one owned only in the base manifest
#   ordinary           no VERSION change; adds adopter shell nowhere in a manifest
#   hand-edit          no VERSION change; edits an owned .claude/hooks script
#   hand-edit-release  the same edit plus a VERSION bump
#   mixed              VERSION bump; adds scripts/deploy.sh; edits an owned script
release_skip_apply() {
  local root="$1" kind="$2"
  case "$kind" in
    release)
      _release_skip_bump_version "$root"
      _release_skip_manifest "$root/.gaia/manifest.json" \
        .gaia/scripts/gaia-tool.sh .claude/hooks/gaia-guard.sh \
        .gaia/scripts/gaia-new.sh .github/audit/gaia-audit.sh
      _release_skip_write "$root" .gaia/scripts/gaia-tool.sh 'echo updated'
      _release_skip_write "$root" .claude/hooks/gaia-guard.sh 'echo updated'
      _release_skip_write "$root" .github/audit/gaia-audit.sh 'echo updated'
      _release_skip_write "$root" .gaia/scripts/gaia-new.sh '#!/usr/bin/env bash'
      git -C "$root" rm -q .gaia/scripts/gaia-retired.sh
      ;;
    ordinary)
      _release_skip_write "$root" .gaia/scripts/my-tool.sh '#!/usr/bin/env bash'
      _release_skip_write "$root" scripts/deploy.sh '#!/usr/bin/env bash'
      _release_skip_write "$root" tests/deploy.bats '#!/usr/bin/env bats'
      _release_skip_write "$root" .claude/hooks/my-guard.sh '#!/usr/bin/env bash'
      ;;
    hand-edit)
      _release_skip_write "$root" .claude/hooks/gaia-guard.sh 'echo adopter edit'
      ;;
    hand-edit-release)
      _release_skip_bump_version "$root"
      _release_skip_write "$root" .claude/hooks/gaia-guard.sh 'echo adopter edit'
      ;;
    mixed)
      _release_skip_bump_version "$root"
      _release_skip_write "$root" scripts/deploy.sh '#!/usr/bin/env bash'
      _release_skip_write "$root" .gaia/scripts/gaia-tool.sh 'echo updated'
      ;;
    *) return 1 ;;
  esac
  git -C "$root" add -A
  git -C "$root" commit -q -m "release-skip $kind"
}

# release_skip_branch <root> <kind>: checks out branch <kind> from main and
# applies it.
release_skip_branch() {
  git -C "$1" checkout -q -b "$2" main
  release_skip_apply "$1" "$2"
}
