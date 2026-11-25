# Shell CWD

Do not `cd` in Bash tool calls. Use absolute paths for every command.

Why: `wiki/concepts/Claude Hooks.md` ("Why `.claude/rules/shell-cwd.md` bans `cd`").

## How to apply

- `git -C /abs/path status`, not `cd /abs/path && git status`
- A relative path in GAIA's instructions (`bash .gaia/scripts/<script>.sh`, `jq ... .gaia/project.json`) resolves from the session root, where every call runs while none has `cd`'d: run it as written, with no `cd <root>` prefix.

If the user explicitly asks for `cd`, follow with an absolute `cd` back to the repo root in the same call.
