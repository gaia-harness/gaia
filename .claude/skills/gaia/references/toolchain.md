# Toolchain

The one statement of how a new project or clone gets pnpm and Chromium, and of how a tool below GAIA's floor is brought up to it. `/gaia-init` Steps 0 and 1, `/setup-gaia` Phase 0 and 0b, and `/update-gaia` Step 3c2 each read the section they need, and the caller says what a stop means for it. `.gaia/toolchain-floors.tsv` holds the floors; `.gaia/scripts/toolchain-check.sh` reads it, so nothing here names a version. Run everything from the project root, so pnpm applies the `packageManager` pin.

## Below a floor

The caller's `toolchain-check.sh` call exited 1. Bring each short tool up to its latest release in this run, rather than stopping. For each `BELOW` or `MISSING` line, show the tool, its installed version and its floor with its `GUIDE` line verbatim, then act on that tool's `ROUTE` line by its class:

- **pnpm**, whatever its class: run `## pnpm` below instead.
- **`run`:** ask once with `AskUserQuestion`, naming the tool, the installed version, the floor and the exact command, with options `Install it (Recommended)` and `Stop`. On `Install it`, run the command.
- **`user`:** the command needs `sudo`, whose password Claude cannot type. Give it to the user as `! <command>`, to type in the prompt so it runs in this session, and wait for them to say it ran.
- **`terminal`:** the command is interactive, such as the Homebrew installer, or changes `PATH` that only a new shell sees, such as `winget`. Never run it. Tell the user to run it in a fresh terminal, then start Claude Code again from that terminal and re-run the command that stopped.
- **No `ROUTE` line:** no exact command exists for this machine. The user updates the tool by its `GUIDE` line, then says so.

Then run the caller's check again. A pass continues the same run. A tool that still falls short, or one the user declined, stops. When a `run` install succeeded and the check still prints `BELOW`, an older copy wins on `PATH`: show `command -v <tool>` and stop.

## pnpm

Tell the user: "Checking for pnpm…" then run:

```bash
bash .gaia/scripts/toolchain-check.sh --tool pnpm
```

Branch on its first word:

**`OK`:** continue.

**`MISSING`:** tell the user "Installing pnpm globally: `corepack disable pnpm`, if corepack is here, then `npm install -g pnpm@latest`", then run the block below. If it fails, stop and report the error. Otherwise continue.

**`BELOW`:** a stale pnpm. Do not silently proceed. Ask with `AskUserQuestion` for consent before touching the user's toolchain, naming the installed version and the floor from that line, with exactly these two options:

- **Yes (Recommended)**: "Update pnpm globally: `corepack disable pnpm`, if corepack is here, then `npm install -g pnpm@latest`. Required to continue."
- **No**: "Keep the current pnpm and stop. Nothing has been changed, so it's safe to exit and re-run later."

On **No**, or anything that is not an explicit Yes, stop with a one-line message. On **Yes**, run the block below, then run the check again.

```bash
if command -v corepack &>/dev/null; then corepack disable pnpm; fi
npm install -g pnpm@latest
```

It is a global install, so the user is always told. pnpm then switches itself to the version `package.json` pins. corepack is left out on purpose: the copy bundled with Node 22.22 cannot run a current pnpm, fails with `Cannot find module`, and leaves a broken entry in its cache that a newer corepack still trips on, so the block only removes corepack's `pnpm` shim.

If the check still prints `BELOW`, a non-corepack pnpm (Homebrew, the standalone installer) is shadowing the update earlier on `PATH`. Show which binary wins with `command -v pnpm` and stop: "pnpm <version> at <path> is older than the required <floor> and takes precedence on your PATH. Update or remove it (e.g. `brew upgrade pnpm`, `pnpm self-update`), then re-run."

## Chromium

Stories and hook tests run in headless Chromium and `pnpm install` installs no browsers. Run:

```bash
pnpm -C apps/web exec playwright install chromium
```

It installs Chromium alone into the per-user Playwright cache, without the system libraries `pnpm install:browsers` (`--with-deps`) adds, so it never asks for `sudo`, and it is a quick no-op when the matching Chromium is already installed. If it fails, stop and report the error with the command to retry it. On Linux, a browser launch can still fail with `Host system is missing dependencies`; then give the user `! pnpm -C apps/web exec playwright install-deps chromium` to type in the prompt (it asks for their `sudo` password to install the system libraries).
