# 2.0.0 per-machine catch-up

`/setup-gaia` Phase 5 (`standalone-features.md`) runs this file for the `migrate-2-machine` feature. The 2.0.0 migration sets up only the machine that ran it; every other clone that was on GAIA 1.x carries 1.x leftovers until it catches up here, once, after pulling the merged migration. Run from the main checkout's root, never from a linked worktree (`/setup-gaia` already refuses one).

Contents: Detect; Catch up; Record.

## Detect

Each line names one 1.x leftover still present on this machine:

```bash
[ -e .gaia/cache ] && echo "LEFTOVER cache"
[ -e .gaia/local/handoff ] && echo "LEFTOVER handoff"
for ledger in .gaia/local/harden/declines.json .gaia/local/codify/declines.json; do
  [ -f "$ledger" ] && [ "$(jq -r '.version // empty' "$ledger" 2>/dev/null)" = 1 ] && echo "LEFTOVER ledger $ledger"
done
bash .gaia/scripts/notebook/move.sh check >/dev/null 2>&1; [ $? -eq 3 ] && echo "LEFTOVER notebook"
[ -d .claude/skills/react-doctor ] && echo "LEFTOVER react-doctor"
[ -e .serena ] && echo "LEFTOVER serena-folder"
command -v claude >/dev/null 2>&1 && claude mcp get serena >/dev/null 2>&1 && echo "LEFTOVER serena-server"
git for-each-ref --format='%(refname:short)' 'refs/heads/spec-*' | sed 's/^/LEFTOVER branch /'
```

No line printed means this machine never ran GAIA 1.x, or already caught up: record `not-applicable` (`## Record`) and stop. Otherwise run `## Catch up` for each kind printed, in this order, then the closing items it lists.

## Catch up

Say in one line that this machine is catching up to GAIA 2.0.0, then:

1. **Dependencies.** Run `pnpm install`. A 1.x `node_modules/` predates the `frontend/` package split. When pnpm stops with `ERR_PNPM_BAD_PM_VERSION`, say how to make the version `package.json` pins available (`corepack enable pnpm`) and never bypass the check.
2. **Retired local files** (`cache`, `handoff`, `ledger`). List each printed path, then ask once with `AskUserQuestion` (`Delete the retired GAIA files listed above?`, `Delete them (Recommended)` / `Keep them`). On `Delete them`, from the repository root, in these spellings only (the rm guard allows the relative paths): `rm -rf .gaia/cache`, `rm -rf .gaia/local/handoff`, and `rm -f <ledger path>` for each printed ledger. Tell the user that each candidate they declined in `/gaia-codify` before re-surfaces once.
3. **Notebook** (`notebook`). Run `bash .gaia/scripts/notebook/move.sh run` and show its report. It moves by rename and deletes nothing. A non-zero exit names its cause on stderr: relay it and continue.
4. **React Doctor skill** (`react-doctor`). When `git ls-files .claude/skills/react-doctor` prints anything, the copy is tracked and the migration owns it: say so and skip. When `frontend/.claude/skills/react-doctor` already exists, delete the root copy with `rm <file>` for each file `find .claude/skills/react-doctor -type f` prints, then `find .claude/skills/react-doctor -depth -type d -empty -delete`. Otherwise move it: `mkdir -p frontend/.claude/skills && mv .claude/skills/react-doctor frontend/.claude/skills/react-doctor`. Never `rm -rf` under `.claude/`.
5. **Serena** (`serena-server`, `serena-folder`). Ask once (`GAIA 2.0.0 removed Serena. Remove it from this machine?`, `Remove it (Recommended)` / `Keep it`). On `Remove it`: `claude mcp remove serena -s user` (a not-found error means it was never registered at user scope), then `rm -rf .serena`.
6. **Spec branches** (`branch`). 2.0.0 puts a Conventional Commits type in front of a spec's branch name. For each printed `spec-<nnn>-<slug>` branch that is not merged into the default branch, mint its new name with `bash .gaia/scripts/branch-name-lib.sh name plan spec-<nnn> --type feat --slug "<slug>"`, then ask once for the whole list, old and new names side by side (`Rename these branches and push them?`, `Rename and push (Recommended)` / `Leave them`). On yes, per branch: `git branch -m <old name> <minted name>`, then `git push -u origin <minted name>`. Never delete the remote's old branch.

Then, on every machine that printed any line:

7. **Old variable names.** Search the user's shell profiles and the repository's workflows for the abbreviated names 2.0.0 ignores without warning:

```bash
grep -nE 'GAIA_(LEDGER_LOCK_(TIMEOUT|STALE|POLL)_SECS|SPEC_REMOTE_TIMEOUT_SECS|SPEC_ALLOC_MAX_RETRIES|TITLE_MAX|WIKI_FETCH_MIN_INTERVAL_MINUTES)\b' ~/.zshrc ~/.bashrc ~/.bash_profile ~/.profile ~/.zprofile .github/workflows/* 2>/dev/null
```

   Report each match with its new name: the three `_SECS` names end in `_SECONDS`, and `GAIA_SPEC_REMOTE_TIMEOUT_SECONDS`, `GAIA_SPEC_ALLOCATION_MAXIMUM_RETRIES`, `GAIA_TITLE_MAXIMUM_LENGTH` and `GAIA_WIKI_FETCH_MINIMUM_INTERVAL_MINUTES` replace the other four. Offer to edit a match in the repository's workflows; leave the user's profile files to them. Claude never opens `.env` files, so tell the user to check `frontend/.env` for the same names.
8. **claude-obsidian.** 2.0.0 no longer enables it. When `claude plugin list 2>/dev/null | grep -q claude-obsidian` passes, ask (`Do you use claude-obsidian outside GAIA?`, `No, uninstall it (Recommended)` / `Yes, keep it`). On `No`: `claude plugin uninstall claude-obsidian@agricidaniel-claude-obsidian --scope user`, which removes it from every project on the machine.
9. **Leftover-file cleanup.** Run it as `.claude/skills/gaia/references/work-lifecycle.md` (`### Leftover-file cleanup after an update merge`) does, from this main checkout: list, ask once, apply on the yes.

A failed step is reported with its error and does not stop the next one.

## Record

Run the record line `standalone-features.md` names for the outcome: `.gaia/cli/gaia setup record migrate-2-machine not-applicable` when `## Detect` printed nothing, otherwise `.gaia/cli/gaia setup record migrate-2-machine applied` once every step has run, declined answers included. A step that failed records nothing, so the next `/setup-gaia` run detects what is left and retries.
