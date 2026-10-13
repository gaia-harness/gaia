# Statusline left-side question

`/setup-gaia` Phase 4.6 reads this file, whole, on every run for `## The routing warning`, and when its gate says a choice or a record is owed. Control returns to Phase 4.6 of `setup-gaia.md`, which falls through to Phase 5.

## The routing warning

Find the statusLine the project actually runs: the first of `.claude/settings.local.json`, `.claude/settings.json` and `~/.claude/settings.json` that sets `statusLine.command`.

```bash
EFFECTIVE_STATUSLINE=""; EFFECTIVE_SOURCE=""
for f in .claude/settings.local.json .claude/settings.json "$HOME/.claude/settings.json"; do
  c="$(jq -r '.statusLine.command // empty' "$f" 2>/dev/null)"
  if [ -n "$c" ]; then EFFECTIVE_STATUSLINE="$c"; EFFECTIVE_SOURCE="$f"; break; fi
done
printf '%s\n%s\n' "$EFFECTIVE_SOURCE" "$EFFECTIVE_STATUSLINE"
```

The command routes through GAIA when its text names `gaia-statusline.sh`, or when it runs a wrapper script whose own text names `gaia-statusline.sh` (read the script the command runs, one level deep). Otherwise print this warning, filling in the source file, and continue; it is advisory and changes nothing:

> Warning: this project's effective statusLine (from `<EFFECTIVE_SOURCE>`) does not run `.gaia/statusline/gaia-statusline.sh`. Without it you get no GAIA nudges, and no context readings are written, so the audit loop's checkpoint falls back to counting rounds. To fix it, remove the `statusLine` key from `<EFFECTIVE_SOURCE>` (when that is `.claude/settings.local.json`), or point it at a wrapper that runs `gaia-statusline.sh`. `/gaia-fitness` reports the same condition when the source is `.claude/settings.json`.

The choice below still runs after the warning: it takes effect once the statusLine is routed through GAIA again.

## The question

Use `AskUserQuestion`, header **`Statusline`**, question "You have your own global statusline. Which one should draw the left side of the statusline in this project?", with these two options in this exact order:

- **Use GAIA's statusline bar (Recommended)**: project, branch, model and effort, and a context bar whose colors match the audit checkpoint line.
- **Keep my own statusline**: your global `statusLine.command` keeps drawing the left side.

Either way GAIA's nudges stay on the right and context readings are still written. Choosing "Other" or dismissing the question writes nothing, so the question re-fires on a later `/setup-gaia` run.

## The write

Write `gaia` for the first option or `user` for the second, keeping any other key already in the file. A file without version 1, or one that does not parse, is replaced, since the statusline reads it as missing anyway:

```bash
LEFT="<gaia|user>"
mkdir -p .gaia/local
tmp="$(mktemp .gaia/local/settings.json.XXXXXX)"
if jq -e 'type == "object" and .version == 1' .gaia/local/settings.json >/dev/null 2>&1; then
  jq --arg left "$LEFT" '.statusline = ((.statusline | if type == "object" then . else {} end) + {left: $left})' .gaia/local/settings.json >"$tmp"
else
  jq -n --arg left "$LEFT" '{version: 1, statusline: {left: $left}}' >"$tmp"
fi && mv -f "$tmp" .gaia/local/settings.json || rm -f "$tmp"
```

Then record the choice: `gaia` runs `.gaia/cli/gaia setup record statusline-left applied`, `user` runs `.gaia/cli/gaia setup record statusline-left declined`. "Other" or a dismissal wrote nothing and records nothing.

The statusline reads the choice on its next render; no restart is needed. Nothing is committed: the file is gitignored. This file is not `.gaia/local/protected/checkpoint-override.json`, the human-only audit checkpoint override, which Claude never writes.

## Record a settled choice

Run when `statusline-left` is owed and no question is needed: no global statusline, or a `gaia` or `user` choice that stands. Run with Phase 4.6's `GLOBAL_STATUSLINE` and `LEFT_CHOICE`:

```bash
if [ -z "$GLOBAL_STATUSLINE" ]; then
  .gaia/cli/gaia setup record statusline-left not-applicable
elif [ "$LEFT_CHOICE" = gaia ]; then
  .gaia/cli/gaia setup record statusline-left applied
elif [ "$LEFT_CHOICE" = user ]; then
  .gaia/cli/gaia setup record statusline-left declined
fi
```

With no global statusline there is nothing to choose between, so the id records `not-applicable`; a global statusline added later re-opens the choice through Phase 4.6's own gate.
