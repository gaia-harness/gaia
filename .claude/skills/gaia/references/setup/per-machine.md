# Per-machine setup

The four per-machine steps `/gaia-init` (Step 8) and `/setup-gaia` (Phase 2) share: external tools, Claude plugins, the statusline executable bit, and the app `.env`. Run from the repository root. The calling command says what a halt means for it and how to resume.

For each step below, read `completed_steps` from `.gaia/cli/gaia setup status --json`, then:

- A step already in `completed_steps` is not re-run. When its id is owed (the owed check in `setup-decisions.md`), run its record line.
- A step with probes (see `## Probes`) runs its probes first, before its install. When every probe passes, it skips the install, runs `.gaia/cli/gaia setup mark-step <step>` and its record line. Otherwise it runs its commands, then its probes again; when every probe passes, it marks the step and runs its record line.
- A step without probes runs its commands, marks the step, and runs its record line.

A failed command, or a probe that still fails after the install: print one `[ok]` or `[FAIL]` line per probe run so far, surface the error verbatim, record nothing, and halt the calling command.

## Step 1: install-tools

Three external tools need per-machine setup. Probes: React Doctor, Playwright CLI, Serena.

- [React Doctor](https://github.com/millionco/react-doctor): Run `bash .gaia/scripts/install-react-doctor.sh`. It installs the Claude Code skill under `frontend/.claude/skills/`, strips the installer's extras, and leaves `package.json`, `pnpm-lock.yaml` and `.githooks/pre-commit` unchanged; `wiki/dependencies/react-doctor.md` holds the verification record. It scans for React-specific issues, and `code-audit-frontend` runs it pre-merge.
- [Playwright CLI](https://github.com/microsoft/playwright-cli): `npm install -g @playwright/cli@latest`. The bundled skill shells out to the global binary; `/update-deps` keeps it current; `wiki/dependencies/playwright-cli.md` covers the fallback.
- [Serena](https://github.com/oraios/serena) MCP server: semantic code search and editing backed by language servers. It needs `uv` first:

  ```bash
  if ! command -v uv &>/dev/null; then
    curl -LsSf https://astral.sh/uv/install.sh | sh
  fi
  ```

  Verify with `uv --version`, sourcing the shell rc the installer modified (or adding `~/.local/bin` to `PATH` for this session) if needed. On failure, halt with: `uv is required for GAIA. Install with: curl -LsSf https://astral.sh/uv/install.sh | sh`. Then register Serena globally:

  ```bash
  claude mcp add serena -s user -- uvx --from git+https://github.com/oraios/serena@v1.7.0 serena start-mcp-server --context claude-code --project-from-cwd --open-web-dashboard false
  ```

  `claude mcp add` exiting non-zero with a "name already exists" error is success. A stale pin on an existing registration needs `claude mcp remove serena -s user`, then the add above. The pinned ref keeps every install on one Serena baseline.

  Serena's tools only win over Claude's built-in Read, Grep and Edit when Claude Code loads Serena's system-prompt override. Tell the user the recommended way to start sessions in this project:

  ```bash
  claude --append-system-prompt="$(serena prompts print-cc-system-prompt-override)"
  ```

  This is optional and adopter-safe: a plain `claude` still works, and `.claude/rules/serena-cc-override.md` is the durable fallback. Use the append form, never `--system-prompt`, which replaces Claude Code's base prompt.

  Serena picks one language at first startup and freezes it into `.serena/project.yml`. When the project grows another language, update the `language_servers:` list (`languages:` before Serena 1.7) in that file and restart Serena; `/gaia-serena-sync` automates the same edit on explicit consent.

Record line: `.gaia/cli/gaia setup record install-tools applied`.

## Step 2: install-plugins

```bash
claude plugin install typescript-lsp@claude-plugins-official
```

Probes: typescript-lsp. An already-installed plugin is a no-op.

Record line: `.gaia/cli/gaia setup record install-plugins applied`.

## Step 3: chmod-statusline

The statusline command in `.claude/settings.json` points at `.gaia/statusline/*.sh`. The executable bit is normally tracked by git but can be lost on cross-platform clones. Idempotent:

```bash
chmod +x .gaia/statusline/*.sh
```

Record line: `.gaia/cli/gaia setup record chmod-statusline applied`.

## Step 4: bootstrap-env

The app's `.env` lives in the `frontend/` package and is gitignored. When `frontend/.env` is absent and `frontend/.env.example` exists, the CLI copies it; otherwise it is a no-op (the project may not use `.env`, or an earlier bootstrap already wrote it):

```bash
.gaia/cli/gaia setup bootstrap-env
```

Run the CLI, never a `cp` onto `frontend/.env`: the project's `Edit(frontend/.env)` deny refuses any Bash command that writes that file, guarded or not, while the CLI subprocess is outside its reach.

Record line: `.gaia/cli/gaia setup record bootstrap-env applied`.

## Probes

After a step's commands, run each of its probes and emit one line per component: `[ok] <component>` when the probe exits 0, `[FAIL] <component>` when it exits non-zero.

| Component      | Probe                                                                        |
| -------------- | ---------------------------------------------------------------------------- |
| React Doctor   | `[ -d frontend/.claude/skills/react-doctor ]` (gitignored, kept per-machine) |
| Playwright CLI | `command -v playwright-cli && playwright-cli --version >/dev/null 2>&1`      |
| Serena         | `claude mcp list 2>/dev/null \| grep -q '^serena:'`                          |
| typescript-lsp | `claude plugin list 2>/dev/null \| grep -q 'typescript-lsp'`                 |
