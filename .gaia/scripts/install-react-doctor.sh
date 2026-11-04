#!/usr/bin/env bash
# Installs GAIA's react-doctor Claude Code skill into a web-stack member's .claude/skills/. The
# skill is rendered from the tracked template in .gaia/templates/react-doctor/, with the version
# pinned in .gaia/react-doctor-version substituted for {{REACT_DOCTOR_VERSION}}. react-doctor's own
# installer is never run: its skill answers `/doctor` (Claude Code's built-in) and fetches remote
# instructions at run time, and everything else it writes is project churn GAIA would remove.
#
# Usage: bash .gaia/scripts/install-react-doctor.sh [--refresh]   (from the repository root)
#
# --refresh reinstalls only where a web-stack member already holds the skill, and exits 0 with one
# line when none does, so a cleanup step never adds the skill to a project that never had it. It
# replaces the whole skill directory, so a skill react-doctor's installer wrote is replaced too.
#
# Exit codes: 0 done (or nothing to do), 1 a step failed, 2 usage error.
#
# The package directory is the web-stack member of `.gaia/packages.json`, whatever its name or
# path: the one already holding the skill, else the first. Installing there makes the skill list
# only for React work. With no web-stack member the script prints one line and exits 0.

set -euo pipefail

usage="Usage: bash .gaia/scripts/install-react-doctor.sh [--refresh] (run from the repository root)"
version_file=".gaia/react-doctor-version"
template_directory=".gaia/templates/react-doctor"
staging_directory=""

fail() {
  printf 'install-react-doctor: %s\n' "$1" >&2
  exit 1
}

remove_staging() {
  if [ -n "$staging_directory" ]; then
    rm -rf "$staging_directory"
  fi
}

refresh_only=0
if [ "$#" -gt 0 ]; then
  if [ "$1" = "--help" ] && [ "$#" -eq 1 ]; then
    printf '%s\n' "$usage"
    exit 0
  fi
  if [ "$1" = "--refresh" ] && [ "$#" -eq 1 ]; then
    refresh_only=1
  else
    printf '%s\n' "$usage" >&2
    exit 2
  fi
fi

packages_library=".claude/hooks/lib/gaia-packages.sh"
[ -f "$packages_library" ] || fail "$packages_library not found; run from the repository root"
# shellcheck source=../../.claude/hooks/lib/gaia-packages.sh
. "$packages_library"
load_status=0
gaia_packages_load . || load_status=$?
[ "$load_status" -eq 0 ] || fail "$GAIA_PACKAGES_ERROR"

package_directory=""
first_web_directory=""
while IFS=$'\t' read -r member_name member_path; do
  [ -n "$member_name" ] || continue
  [ -n "$first_web_directory" ] || first_web_directory="$member_path"
  if [ -d "$member_path/.claude/skills/react-doctor" ]; then
    package_directory="$member_path"
    break
  fi
done < <(gaia_packages_web_members)
if [ -z "$package_directory" ] && [ "$refresh_only" -eq 1 ]; then
  printf 'install-react-doctor: no web-stack member holds the react-doctor skill; nothing to refresh\n' >&2
  exit 0
fi
[ -n "$package_directory" ] || package_directory="$first_web_directory"
if [ -z "$package_directory" ]; then
  printf 'install-react-doctor: no package in .gaia/packages.json declares "stack": "web"; nothing to install\n' >&2
  exit 0
fi
skill_directory="$package_directory/.claude/skills/react-doctor"

# shellcheck source=react-doctor-version-lib.sh
. .gaia/scripts/react-doctor-version-lib.sh
react_doctor_version="$(react_doctor_pinned_version "$version_file")" || exit 1
[ -f "$template_directory/SKILL.md" ] || fail "skill template $template_directory/SKILL.md not found"

# Render beside the target, then swap, so a failed render leaves any installed skill untouched.
mkdir -p "$package_directory/.claude/skills"
staging_directory="$(mktemp -d "$package_directory/.claude/skills/.react-doctor.XXXXXX")"
trap remove_staging EXIT
while IFS= read -r template_file; do
  relative_path="${template_file#"$template_directory"/}"
  mkdir -p "$staging_directory/$(dirname "$relative_path")"
  sed "s/{{REACT_DOCTOR_VERSION}}/$react_doctor_version/g" "$template_file" >"$staging_directory/$relative_path" \
    || fail "rendering $template_file failed"
done < <(find "$template_directory" -type f)
rm -rf "$skill_directory"
mv "$staging_directory" "$skill_directory" || fail "moving the rendered skill into $skill_directory failed"
staging_directory=""

# Re-arm the hook path: a clone whose dependencies were installed before `git init` skipped `prepare`.
if [ "$(git config --local --get core.hooksPath || true)" != ".githooks" ]; then
  git config core.hooksPath .githooks || fail "git config step failed setting core.hooksPath"
fi
