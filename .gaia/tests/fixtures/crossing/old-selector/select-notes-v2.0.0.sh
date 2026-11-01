# shellcheck shell=bash
# select_notes from .gaia/scripts/update-gaia-preflight.sh at v2.0.0, verbatim below these lines.
# The caller sets latest_dir, baseline and latest, as that script's flag parse does.
# shellcheck disable=SC2154
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
