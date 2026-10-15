#!/usr/bin/env bash
# Create a tmp git repo seeded with a notebook and its catalog, for testing the
# scripts that read and write it. Prints the repo path on stdout (and the linked
# worktree path on a second line when --worktree or --worktree-bare is given).
# Sibling of tmp-spec-repo.sh, which seeds the per-kind ledgers instead.
#
# Inside the tmp repo:
#   - git init (main), test identity, commit.gpgsign false, a .gitignore that
#     carries .gaia/local, .gaia/local.bak.*, .notebook and .notebook.bak.*,
#     and one initial commit
#   - copies (NOT symlinks) of the notebook scripts, the spec scripts, the
#     main-root, branch-name, audit-loop-state and audit-key libraries,
#     plan-archive.sh and summary-verify.sh, plus usage.sh with every library
#     it sources (through helpers/usage-gate.sh) and an empty
#     .gaia/local/telemetry/usage.jsonl. Whatever exists at call time is
#     copied, so the helper keeps working while those scripts change; a missing
#     source is named on stderr and skipped.
#   - .notebook/catalog.json = {"version":1,"move_complete":{...},"items":[...]}
#
# Sourcing this file defines seed_close_row (from usage-gate.sh) and does
# nothing else.
#
# Seed flags (repeatable, order-independent). Each appends one catalog row,
# written directly as JSON. created_at and status_changed_at carry a fixed old
# stamp unless an --at <iso> flag came right before the seed flag; --at applies
# to the next seed flag only. A merged row also gets merged_at and an abandoned
# row also gets abandoned_at, each equal to the stamp.
#   --at <iso>                       stamp for the next seed flag
#   --seed-spec <ID> <status>        row only
#   --seed-spec-folder <ID> <status> row plus .notebook/specs/<ID>/SPEC.md
#   --seed-spec-merged-folder <ID>   merged row plus SPEC.md and SUMMARY.md
#   --seed-spec-abandoned-folder <ID>  abandoned row plus AUDIT.md only
#   --seed-spec-provisional <ID> [subject]  draft row, reservation provisional
#   --seed-spec-file <ID>            bare .notebook/specs/<ID>.md, no row
#   --seed-row '<json-object>'       the object, appended verbatim
#   --seed-plan <ID> <status>        row only
#   --seed-plan-folder <ID> <status> row plus .notebook/plans/<ID>/PROGRESS.md
#   --seed-research <slug> <status>  row plus .notebook/research/<slug>/README.md
#   --seed-research-folder-only <slug>  folder with README.md, no row
#   --seed-research-loose <name>     regular file directly under research/
#
# Shape flags:
#   --legacy       also create .gaia/local/specs/ledger.json and leave
#                  move_complete out of the catalog (a not-ready repo)
#   --no-catalog   write no catalog and create no .notebook directory (a fresh
#                  adopter repo); incompatible with the seed flags
#   --worktree <name>       real linked worktree at <repo>-<name> (second
#                           stdout line) with .notebook and .gaia/local symlinks
#                           into the repo
#   --worktree-bare <name>  the same linked worktree with neither link
#
# Remote flags (order-DEPENDENT: --with-origin must precede the other two; they
# run after the initial commit, in the order given):
#   --with-origin               bare origin at "<repo>.git", added as origin,
#                               main pushed
#   --seed-remote-tag spec/NNN [subject]  push an annotated empty-tree tag
#                               straight into the bare origin; the repo's own
#                               tag list stays empty
#   --origin-reject-spec-tags   install an update hook in the origin rejecting
#                               refs/tags/spec/*, and pin the origin's
#                               core.hooksPath to its own hooks/ so a global
#                               core.hooksPath cannot bypass it
#
# Second clone: helpers/clone-spec-repo.sh <repo>.git.

_helper_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=usage-gate.sh
. "${_helper_directory}/usage-gate.sh"

if [ "${BASH_SOURCE[0]}" != "$0" ]; then
  return 0
fi

set -euo pipefail

EMPTY_TREE="4b825dc642cb6eb9a060e54bf8d69288fbee4904"
UNIT_SEPARATOR=$'\x1f'
OLD_STAMP="2026-01-01T00:00:00Z"

real_repo="$(git -C "$_helper_directory" rev-parse --show-toplevel)"
real_scripts="${real_repo}/.gaia/scripts"

repository_directory="$(mktemp -d -t gaia-notebook-test-XXXXXX)"
repository_directory="$(cd "$repository_directory" && pwd -P)"
cd "$repository_directory"

git init --quiet --initial-branch=main
git config user.email "test@example.com"
git config user.name "Test"
git config commit.gpgsign false

printf '.gaia/local\n.gaia/local.bak.*\n.notebook\n.notebook.bak.*\n' > .gitignore

mkdir -p .gaia/local/cache .gaia/local/telemetry .gaia/scripts/spec

# Copy (not symlink) so each script's ${BASH_SOURCE[0]}-relative sourcing
# resolves inside this tmp repo.
copy_scripts() {
  local source_directory="$1" destination_directory="$2" source_file copied=0
  mkdir -p "$destination_directory"
  for source_file in "$source_directory"/*.sh; do
    [ -f "$source_file" ] || continue
    cp "$source_file" "$destination_directory/$(basename "$source_file")"
    chmod +x "$destination_directory/$(basename "$source_file")"
    copied=1
  done
  if [ "$copied" -eq 0 ]; then
    echo "tmp-notebook-repo.sh: skipped copy of ${source_directory#"${real_repo}/"}/*.sh: no scripts found" >&2
  fi
}

copy_one() {
  local relative_path="$1" optional="${2:-required}"
  if [ -f "${real_repo}/${relative_path}" ]; then
    mkdir -p "$(dirname "$relative_path")"
    cp "${real_repo}/${relative_path}" "$relative_path"
    chmod +x "$relative_path"
  elif [ "$optional" = required ]; then
    echo "tmp-notebook-repo.sh: skipped copy of ${relative_path}: not found" >&2
  fi
}

if [ -d "${real_scripts}/notebook" ]; then
  copy_scripts "${real_scripts}/notebook" .gaia/scripts/notebook
else
  echo "tmp-notebook-repo.sh: skipped copy of .gaia/scripts/notebook: directory not found" >&2
fi
copy_scripts "${real_scripts}/spec" .gaia/scripts/spec
for script_name in main-root-lib.sh branch-name-lib.sh audit-loop-state-lib.sh audit-key-lib.sh plan-archive.sh; do
  copy_one ".gaia/scripts/${script_name}"
done
copy_one .gaia/scripts/summary-verify.sh optional

copy_usage_gate "$real_repo" "$repository_directory"
: > .gaia/local/telemetry/usage.jsonl

rows_file="$(mktemp)"
trap 'rm -f "$rows_file"' EXIT
legacy=false
no_catalog=false
seeded=false
pending_stamp=""
remote_ops=()
worktree_requests=()

# Append one catalog row built from the named seed. Arguments: kind id status
# subject [extra-json-object]. Consumes pending_stamp.
append_row() {
  local kind="$1" id="$2" status="$3" subject="$4" extra="${5:-{\}}" stamp directory_name
  stamp="${pending_stamp:-$OLD_STAMP}"
  pending_stamp=""
  case "$kind" in
    spec) directory_name=specs ;;
    plan) directory_name=plans ;;
    *) directory_name=research ;;
  esac
  jq -cn --arg kind "$kind" --arg id "$id" --arg status "$status" \
    --arg subject "$subject" --arg stamp "$stamp" --arg directory "$directory_name" \
    --argjson extra "$extra" '
    {kind: $kind, id: $id, path: ($directory + "/" + $id), status: $status,
     subject: $subject, created_at: $stamp, status_changed_at: $stamp}
    + (if ($kind == "spec" or $kind == "plan") and $status == "merged" then {merged_at: $stamp}
       elif ($kind == "spec" or $kind == "plan") and $status == "abandoned" then {abandoned_at: $stamp}
       else {} end)
    + $extra' >> "$rows_file"
  seeded=true
}

# Optional trailing operand: the next argument unless it is a flag.
optional_operand() {
  if [ "$#" -gt 1 ] && [[ "$2" != --* ]]; then
    printf '%s' "$2"
  else
    printf '%s' "$1"
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --at)
      pending_stamp="$2"; shift 2
      ;;
    --seed-spec)
      append_row spec "$2" "$3" "$2"; shift 3
      ;;
    --seed-spec-folder)
      append_row spec "$2" "$3" "$2"
      mkdir -p ".notebook/specs/$2"
      printf -- '---\nspec_id: %s\nstatus: %s\nimmutable: true\n---\n\n# %s\n' "$2" "$3" "$2" > ".notebook/specs/$2/SPEC.md"
      shift 3
      ;;
    --seed-spec-merged-folder)
      append_row spec "$2" merged "$2"
      mkdir -p ".notebook/specs/$2"
      printf -- '---\nspec_id: %s\nstatus: specified\nimmutable: true\n---\n\n# %s\n' "$2" "$2" > ".notebook/specs/$2/SPEC.md"
      printf -- '---\nwiki_promote_default: ask\nwiki_promote_targets: []\n---\n# %s\n\nConsolidated summary body.\n' "$2" > ".notebook/specs/$2/SUMMARY.md"
      shift 2
      ;;
    --seed-spec-abandoned-folder)
      append_row spec "$2" abandoned "$2"
      mkdir -p ".notebook/specs/$2"
      printf '# %s Adversarial Audit\n\nVerdict body.\n' "$2" > ".notebook/specs/$2/AUDIT.md"
      shift 2
      ;;
    --seed-spec-provisional)
      provisional_id="$2"
      provisional_subject="$(optional_operand "$provisional_id" "${@:3}")"
      if [ "$provisional_subject" = "$provisional_id" ]; then shift 2; else shift 3; fi
      append_row spec "$provisional_id" draft "$provisional_subject" '{"reservation":"provisional"}'
      ;;
    --seed-spec-file)
      mkdir -p .notebook/specs
      printf -- '---\nspec_id: %s\nstatus: in-progress\n---\n\n# %s\n' "$2" "$2" > ".notebook/specs/$2.md"
      seeded=true
      shift 2
      ;;
    --seed-row)
      if ! printf '%s' "$2" | jq -e 'type == "object"' >/dev/null 2>&1; then
        echo "tmp-notebook-repo.sh: --seed-row needs a JSON object" >&2
        exit 1
      fi
      printf '%s' "$2" | jq -c . >> "$rows_file"
      seeded=true
      shift 2
      ;;
    --seed-plan)
      append_row plan "$2" "$3" "$2"; shift 3
      ;;
    --seed-plan-folder)
      append_row plan "$2" "$3" "$2"
      mkdir -p ".notebook/plans/$2"
      printf '# %s\n\nProgress body.\n' "$2" > ".notebook/plans/$2/PROGRESS.md"
      shift 3
      ;;
    --seed-research)
      append_row research "$2" "$3" "$2"
      mkdir -p ".notebook/research/$2"
      printf '# %s\n\nResearch body.\n' "$2" > ".notebook/research/$2/README.md"
      shift 3
      ;;
    --seed-research-folder-only)
      mkdir -p ".notebook/research/$2"
      printf '# %s\n\nResearch body.\n' "$2" > ".notebook/research/$2/README.md"
      seeded=true
      shift 2
      ;;
    --seed-research-loose)
      mkdir -p .notebook/research
      printf 'loose file\n' > ".notebook/research/$2"
      seeded=true
      shift 2
      ;;
    --legacy)
      legacy=true; shift
      ;;
    --no-catalog)
      no_catalog=true; shift
      ;;
    --worktree)
      worktree_requests+=("linked${UNIT_SEPARATOR}$2"); shift 2
      ;;
    --worktree-bare)
      worktree_requests+=("bare${UNIT_SEPARATOR}$2"); shift 2
      ;;
    --with-origin)
      remote_ops+=("with-origin${UNIT_SEPARATOR}${UNIT_SEPARATOR}")
      shift
      ;;
    --seed-remote-tag)
      tag="$2"; shift 2
      subject="$tag"
      if [[ $# -gt 0 && "$1" != --* ]]; then
        subject="$1"; shift
      fi
      remote_ops+=("seed-remote-tag${UNIT_SEPARATOR}${tag}${UNIT_SEPARATOR}${subject}")
      ;;
    --origin-reject-spec-tags)
      remote_ops+=("origin-reject-spec-tags${UNIT_SEPARATOR}${UNIT_SEPARATOR}")
      shift
      ;;
    *)
      echo "tmp-notebook-repo.sh: unknown arg: $1" >&2
      exit 1
      ;;
  esac
done

if [ "$no_catalog" = true ]; then
  if [ "$seeded" = true ]; then
    echo "tmp-notebook-repo.sh: --no-catalog cannot combine with a seed flag" >&2
    exit 1
  fi
  rm -rf .notebook
else
  mkdir -p .notebook
  if [ "$legacy" = true ]; then
    jq -n --slurpfile rows "$rows_file" '{version: 1, items: $rows}' > .notebook/catalog.json
  else
    jq -n --arg stamp "$OLD_STAMP" --slurpfile rows "$rows_file" \
      '{version: 1, move_complete: {at: $stamp}, items: $rows}' > .notebook/catalog.json
  fi
fi

if [ "$legacy" = true ]; then
  mkdir -p .gaia/local/specs
  printf '{\n  "version": 1,\n  "specs": []\n}\n' > .gaia/local/specs/ledger.json
fi

git add -A
git commit --quiet -m "init"

# Remote ops run in argument order now that main has a commit to push.
origin_directory=""
for remote_operation in ${remote_ops[@]+"${remote_ops[@]}"}; do
  IFS="$UNIT_SEPARATOR" read -r operation_type operation_first_argument operation_second_argument <<< "$remote_operation"
  case "$operation_type" in
    with-origin)
      origin_directory="${repository_directory}.git"
      git init --quiet --bare --initial-branch=main "$origin_directory"
      git remote add origin "$origin_directory"
      git push --quiet -u origin main
      ;;
    seed-remote-tag)
      if [ -z "$origin_directory" ]; then
        echo "tmp-notebook-repo.sh: --seed-remote-tag requires --with-origin earlier in the argument list" >&2
        exit 1
      fi
      git tag -a "$operation_first_argument" "$EMPTY_TREE" -m "$operation_second_argument"
      git push --quiet origin "refs/tags/$operation_first_argument"
      git tag -d "$operation_first_argument" >/dev/null
      ;;
    origin-reject-spec-tags)
      if [ -z "$origin_directory" ]; then
        echo "tmp-notebook-repo.sh: --origin-reject-spec-tags requires --with-origin earlier in the argument list" >&2
        exit 1
      fi
      # A global core.hooksPath would override the origin's own hooks/ and
      # silently skip the reject hook, so pin the path back to it.
      git -C "$origin_directory" config core.hooksPath "$origin_directory/hooks"
      mkdir -p "$origin_directory/hooks"
      cat > "$origin_directory/hooks/update" <<'HOOK'
#!/bin/sh
# update <refname> <old-sha> <new-sha>; reject any spec/* tag reservation,
# allow everything else (including the initial main push).
case "$1" in
  refs/tags/spec/*)
    echo "reject: refs/tags/spec/* namespace is protected" >&2
    exit 1
    ;;
esac
exit 0
HOOK
      chmod +x "$origin_directory/hooks/update"
      ;;
  esac
done

echo "$repository_directory"

for worktree_request in ${worktree_requests[@]+"${worktree_requests[@]}"}; do
  IFS="$UNIT_SEPARATOR" read -r worktree_mode worktree_name <<< "$worktree_request"
  worktree_directory="${repository_directory}-${worktree_name}"
  git worktree add --quiet -b "wt-${worktree_name}" "$worktree_directory"
  if [ "$worktree_mode" = linked ]; then
    [ -e "${repository_directory}/.notebook" ] && ln -s "${repository_directory}/.notebook" "${worktree_directory}/.notebook"
    ln -s "${repository_directory}/.gaia/local" "${worktree_directory}/.gaia/local"
  fi
  echo "$worktree_directory"
done
