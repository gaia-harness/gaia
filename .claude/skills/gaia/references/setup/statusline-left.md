# Statusline left-side question

`/setup-gaia` Phase 4.6 reads this file, whole, once its gate says a choice is owed. Control returns to Phase 4.6 of `setup-gaia.md`, which falls through to Phase 6.

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

The statusline reads the choice on its next render; no restart is needed. Nothing is committed: the file is gitignored. This file is not `.gaia/local/protected/checkpoint-override.json`, the human-only audit checkpoint override, which Claude never writes.
