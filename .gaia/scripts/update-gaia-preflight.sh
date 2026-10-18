#!/usr/bin/env bash
# shellcheck shell=bash
#
# update-gaia-preflight.sh: the pre-merge steps of /update-gaia as plain
# subcommands, run with the working directory at the checkout root (the main
# checkout, or the update worktree). Every path stays repo-relative.
#   bash .gaia/scripts/update-gaia-preflight.sh refuse-1x      --baseline <v>
#   bash .gaia/scripts/update-gaia-preflight.sh verify-bundles --baseline <v> --latest-tag <tag> [--extra-tag <tag>]...
#   bash .gaia/scripts/update-gaia-preflight.sh select-notes   --latest-dir <dir> --baseline <v> --latest <v>
#   bash .gaia/scripts/update-gaia-preflight.sh changelog      --baseline <v> --latest <v> --latest-tag <tag> [--save-from <v>]
#   bash .gaia/scripts/update-gaia-preflight.sh prune          --baseline <v> --latest-tag <tag> [--resume] [--keep-tag <tag>]...
#
# WHY A SCRIPT. Inside a linked worktree session the Claude Code runtime
# refuses a command it cannot verify stays inside the worktree: a captured
# command substitution, a shell variable interpolated into a path, a heredoc.
# These steps are full of all three, so each one runs here, where the runtime
# does not inspect the text, as one plain literal-path call.
#
# Each subcommand mirrors the step of the same name in the update-gaia skill:
# refuse-1x is the 1.x baseline refusal, verify-bundles the download and
# checksum verification, select-notes the migration note selection, changelog
# the baseline-to-latest range fetch, and prune the prior-run cleanup.
#
# Exit codes: 0 success; 1 the step's own refusal or failure (its token is
# printed on stdout); 2 a usage error (an unknown subcommand, an unknown flag,
# or a missing required flag), with the usage line on stderr.

usage() {
  cat >&2 <<'USAGE'
usage: update-gaia-preflight.sh refuse-1x      --baseline <v>
       update-gaia-preflight.sh verify-bundles --baseline <v> --latest-tag <tag> [--extra-tag <tag>]...
       update-gaia-preflight.sh select-notes   --latest-dir <dir> --baseline <v> --latest <v>
       update-gaia-preflight.sh changelog      --baseline <v> --latest <v> --latest-tag <tag> [--save-from <v>]
       update-gaia-preflight.sh prune          --baseline <v> --latest-tag <tag> [--resume] [--keep-tag <tag>]...
USAGE
  exit 2
}

# A flag given with an empty value still counts as given, so the 1.x refusal
# can report an empty baseline as malformed instead of as a usage error.
have_baseline=false
have_latest=false
have_latest_tag=false
have_latest_dir=false
resume=false
baseline=''
latest=''
latest_tag=''
latest_dir=''
save_from=''
extra_tags=()
keep_tags=()

# An extra or kept tag reaches a download command and a path, so it is checked
# before anything touches the network or the cache.
tag_pattern='^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$'

[ "$#" -ge 1 ] || usage
subcommand="$1"
shift

while [ "$#" -gt 0 ]; do
  case "$1" in
    --baseline | --latest | --latest-tag | --latest-dir)
      [ "$#" -ge 2 ] || usage
      case "$1" in
        --baseline) baseline="$2"; have_baseline=true ;;
        --latest) latest="$2"; have_latest=true ;;
        --latest-tag) latest_tag="$2"; have_latest_tag=true ;;
        --latest-dir) latest_dir="$2"; have_latest_dir=true ;;
      esac
      shift 2
      ;;
    --extra-tag | --keep-tag | --save-from)
      [ "$#" -ge 2 ] || usage
      case "$1" in
        --extra-tag)
          [[ "$2" =~ $tag_pattern ]] || usage
          extra_tags+=("$2")
          ;;
        --keep-tag)
          [[ "$2" =~ $tag_pattern ]] || usage
          keep_tags+=("$2")
          ;;
        --save-from) save_from="$2" ;;
      esac
      shift 2
      ;;
    --resume)
      resume=true
      shift
      ;;
    *) usage ;;
  esac
done

# Step: refuse a 1.x baseline. A three-way merge from a 1.x baseline would read
# every baseline app path as an upstream deletion (the 2.x manifest is keyed on
# frontend/), so a 1.x project migrates through the 2.0.0 migration note and
# never through this command. It runs before any download so nothing has been
# fetched, created or pruned when it refuses.
refuse_1x() {
  local baseline_major="${baseline%%.*}"
  case "$baseline_major" in
    '' | *[!0-9]*)
      echo "REFUSED: .gaia/VERSION holds '$baseline', which is not a version. Fix .gaia/VERSION, then re-run /update-gaia."
      exit 1
      ;;
  esac
  if [ "$baseline_major" -lt 2 ]; then
    echo "REFUSED: this project is on GAIA $baseline. /update-gaia cannot cross the 2.0.0 layout change. Nothing was changed. This command downloads the v2.0.0 release, verifies its checksum, and extracts it:"
    cat <<'FETCH_COMMAND'
  mkdir -p .gaia/local/cache/shared/migrate-2/v2.0.0/tree && gh release download v2.0.0 --repo gaia-react/gaia --pattern 'gaia-bundle-v2.0.0.tar.gz*' --dir .gaia/local/cache/shared/migrate-2/v2.0.0 --clobber && sed 's|  |  .gaia/local/cache/shared/migrate-2/v2.0.0/|' .gaia/local/cache/shared/migrate-2/v2.0.0/gaia-bundle-v2.0.0.tar.gz.sha256 | shasum -a 256 -c - && tar -xzf .gaia/local/cache/shared/migrate-2/v2.0.0/gaia-bundle-v2.0.0.tar.gz -C .gaia/local/cache/shared/migrate-2/v2.0.0/tree --strip-components=1
FETCH_COMMAND
    echo "Once that command succeeds and the user agrees, follow .gaia/local/cache/shared/migrate-2/v2.0.0/tree/.gaia/migrations/2.0.0.md in this session."
    exit 1
  fi
}

verify_checklist() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 -c - >/dev/null
  else
    sha256sum -c - >/dev/null
  fi
}

# Step: download and verify the bundles. Every bundle the run reads is verified
# against its release's .sha256 asset in this run, and every tree it reads is
# extracted again from that verified tarball. A cached tarball skips only the
# download, never the verification or the extract; there is no verified-marker
# file. The asset is gaia-bundle-<tag>.tar.gz from 2.0.0 on; the different name
# from the earlier gaia-<tag>.tar.gz is what makes a 1.6.1 /update-gaia fail at
# its fetch step, before it writes anything.
verify_bundles() {
  local tag dir tarball extra_tag
  local tags=("v$baseline" "$latest_tag")
  # An extra tag equal to one already listed is fetched once.
  for extra_tag in ${extra_tags[@]+"${extra_tags[@]}"}; do
    case " ${tags[*]} " in
      *" $extra_tag "*) ;;
      *) tags+=("$extra_tag") ;;
    esac
  done
  for tag in "${tags[@]}"; do
    dir=".gaia/local/cache/shared/update-gaia/$tag"
    tarball="gaia-bundle-${tag}.tar.gz"
    # A cached directory with no checksum predates verification: a cache miss.
    if [ -d "$dir" ] && [ ! -f "$dir/$tarball.sha256" ]; then
      rm -rf "$dir"
    fi
    mkdir -p "$dir"
    if [ ! -f "$dir/$tarball" ] || [ ! -f "$dir/$tarball.sha256" ]; then
      if ! gh release download "$tag" --repo gaia-react/gaia \
        --pattern "gaia-bundle-${tag}.tar.gz" \
        --pattern "gaia-bundle-${tag}.tar.gz.sha256" \
        --dir "$dir" --clobber; then
        rm -rf "$dir"
        echo "FETCH_FAILED $tag"
        exit 1
      fi
    fi
    if [ ! -f "$dir/$tarball.sha256" ]; then
      rm -rf "$dir"
      echo "CHECKSUM_MISSING $tag"
      exit 1
    fi
    # The checklist must name this tarball and nothing else, so a checklist for
    # another file can never vouch for it. The sed rewrite points the bare file
    # name at the cache directory, so the check runs from the project root.
    if ! awk -v name="$tarball" 'NF == 2 && $2 == name { matched++ } END { exit !(NR == 1 && matched == 1) }' "$dir/$tarball.sha256" \
      || ! sed "s|  |  $dir/|" "$dir/$tarball.sha256" | verify_checklist; then
      rm -rf "$dir"
      echo "VERIFY_FAILED $tag"
      exit 1
    fi
    rm -rf "$dir/tree"
    mkdir -p "$dir/tree"
    if ! tar -xzf "$dir/$tarball" -C "$dir/tree" --strip-components=1; then
      rm -rf "$dir"
      echo "FETCH_FAILED $tag"
      exit 1
    fi
    echo "VERIFIED $tag"
  done
  echo "BASELINE_DIR=.gaia/local/cache/shared/update-gaia/v$baseline/tree"
  echo "LATEST_DIR=.gaia/local/cache/shared/update-gaia/$latest_tag/tree"
  for extra_tag in ${extra_tags[@]+"${extra_tags[@]}"}; do
    echo "EXTRA_DIR=$extra_tag:.gaia/local/cache/shared/update-gaia/$extra_tag/tree"
  done
}

# Step: select migration notes. The verified target bundle's own selector
# judges the notes, with the bundle as its root, never this checkout's copy, so
# a mode or key a later release adds is judged by that release's selector.
select_notes() {
  local selection selection_status tab note_version note_mode note_path
  selection="$(bash "$latest_dir/.gaia/scripts/select-migration-notes.sh" "$latest_dir" "$baseline" "$latest" 2>&1)"
  selection_status=$?
  if [ "$selection_status" -ne 0 ]; then
    echo "NOTES_FAILED"
    printf '%s\n' "$selection"
    echo "Next step: the target release's migration notes are unreadable, and nothing was changed. Re-run /update-gaia once a fixed release is out, and report the lines above upstream."
    exit 1
  fi
  tab="$(printf '\t')"
  while IFS="$tab" read -r note_version note_mode note_path; do
    [ -n "$note_version" ] || continue
    case "$note_mode" in
      after-merge) echo "AFTER_MERGE $note_version $note_path" ;;
      *)
        # A mode this script does not know reads as blocking, so the note
        # itself says how to follow it.
        echo "BLOCKING $note_version $note_path"
        break
        ;;
    esac
  done <<SELECTED
$selection
SELECTED
}

# Step: the baseline-to-latest CHANGELOG range. The range is saved beside the
# target's verified tree for the summary step's documented adopter actions: the
# release bundle withholds CHANGELOG.md, so this fetch is the only copy. A
# failed fetch removes the file so a stale range is never read. With
# --save-from the saved file starts at that older version (the oldest deferred
# baseline, whose reasons the merge may need) while stdout stays the
# baseline-to-latest range. A prerelease value is cut to its core version
# because the range helper reads only x.y.z.
changelog() {
  local changelog_text range range_file saved_range
  changelog_text="$(curl -fsSL "https://raw.githubusercontent.com/gaia-react/gaia/$latest_tag/CHANGELOG.md" 2>/dev/null)"
  if [ -z "$changelog_text" ] && command -v gh >/dev/null 2>&1; then
    changelog_text="$(gh api "repos/gaia-react/gaia/contents/CHANGELOG.md?ref=$latest_tag" \
      -H "Accept: application/vnd.github.raw" 2>/dev/null)"
  fi

  range="$(printf '%s\n' "$changelog_text" | bash .gaia/scripts/changelog-range.sh "$baseline" "$latest")"
  range_file=".gaia/local/cache/shared/update-gaia/$latest_tag/changelog-range.md"
  saved_range="$range"
  if [ -n "$save_from" ]; then
    saved_range="$(printf '%s\n' "$changelog_text" | bash .gaia/scripts/changelog-range.sh "$save_core" "$latest")"
  fi

  if [ -n "$range" ]; then
    printf '%s\n' "$saved_range" > "$range_file"
    printf '%s\n' "$range"
  else
    rm -f "$range_file"
    # Fetch failed (offline, private, missing file): fall back to the
    # single-tag GitHub release body so the gate still has context.
    gh release view "$latest_tag" --repo gaia-react/gaia --json body --jq .body
  fi
}

# Step: prune prior-run artifacts. Two gitignored directories accumulate
# across updates; this runs at the start of a confirmed update and before the
# run creates any merge artifact of its own, so the current run's fresh safety
# net is never touched.
prune() {
  local d kept_tag
  # .gaia-backup/: prior runs' pre-overwrite copies. Once an update is
  # committed, git history is the durable recovery, so prior backups are
  # redundant. A resumed run keeps them: they are the only copy of what the
  # interrupted run's merge overwrote.
  if [ "$resume" != true ]; then
    rm -rf .gaia-backup
  fi

  # .gaia/local/cache/shared/update-gaia/: keep the baseline and target
  # directories verify-bundles just extracted, plus each --keep-tag (a deferred
  # baseline the merge reads), and delete every other entry. That includes
  # run/, the previous update run's merge report and candidates, which is how a
  # stopped run's leftovers are cleaned up. The glob is the update-gaia/
  # directory only: update-check.json and serena-guard/ live one level up at
  # shared/, structurally outside it.
  if [ -d .gaia/local/cache/shared/update-gaia ]; then
    for d in .gaia/local/cache/shared/update-gaia/*/; do
      [ -d "$d" ] || continue
      case "$(basename "$d")" in
        "v$baseline" | "$latest_tag") continue ;;
      esac
      for kept_tag in ${keep_tags[@]+"${keep_tags[@]}"}; do
        [ "$(basename "$d")" = "$kept_tag" ] && continue 2
      done
      rm -rf "$d"
    done
  fi
}

case "$subcommand" in
  refuse-1x)
    [ "$have_baseline" = true ] || usage
    refuse_1x
    ;;
  verify-bundles)
    [ "$have_baseline" = true ] && [ "$have_latest_tag" = true ] || usage
    verify_bundles
    ;;
  select-notes)
    [ "$have_latest_dir" = true ] && [ "$have_baseline" = true ] && [ "$have_latest" = true ] || usage
    select_notes
    ;;
  changelog)
    [ "$have_baseline" = true ] && [ "$have_latest" = true ] && [ "$have_latest_tag" = true ] || usage
    if [ -n "$save_from" ]; then
      save_core="${save_from%%-*}"
      [[ "$save_core" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || usage
    fi
    changelog
    ;;
  prune)
    [ "$have_baseline" = true ] && [ "$have_latest_tag" = true ] || usage
    prune
    ;;
  *) usage ;;
esac
