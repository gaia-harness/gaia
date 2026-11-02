---
type: concept
status: active
created: 2026-10-03
updated: 2026-11-02
tags: [concept, monorepo, guards, claude]
---

# Package Descriptor

GAIA is a monorepo: the harness (`.claude/`, `.gaia/`, `.githooks/`, `.github/`, `wiki/`) lives at the repo root, apps live in `apps/<name>/` and shared libraries in `packages/<name>/`. Two JSON files tell the harness where a workspace member is and which of its paths each guard cares about, so no guard hardcodes `app/` or `apps/web/`. The layout is GAIA's convention, built on a plain pnpm workspace ([pnpm workspaces](https://pnpm.io/workspaces)) and the apps-and-packages shape that [Nx's pnpm workspace guide](https://nx.dev/docs/kb/pnpm-workspaces) describes.

## The two files

- **Registry, `.gaia/packages.json`.** A list of `{name, path}` entries, one per member. When the file is absent, the harness uses a built-in default registry that registers `web` at `apps/web/`. The default covers only the registry: its descriptor is still read from `apps/web/gaia.package.json`, so that file is the one copy of the default globs and an edit to it takes effect with or without a registry.
- **Descriptor, `<member path>/gaia.package.json`.** Names the member and holds its glob lists: which files are unit tests, which are strict TDD candidates, which tests are emergent, which sources trigger the pre-commit gate, and where the member's dependency manifests and doctor config sit. Every `globs` key is required and each list may be empty. An empty list adds nothing to what that key matches, except an empty `preCommitSource`, which means any staged path in the member plans it. It also carries the `wiki` path lists the wiki tooling reads. Globs are member-relative. Two optional fields:
  - `stack`: the only accepted value is `"web"`. It marks a React app, which gets the frontend tooling, rules and generated settings. Absent means not web.
  - `generatedSettings`: a boolean. A web-stack member always has generated settings; any other member has them only when this is `true`. Default `false`.

The schema lives in the readers and the shipped `apps/web/gaia.package.json` is the worked example; read those rather than a list here.

## Who reads them

Two implementations of one contract, both pinned to the same shared conformance corpus:

- Bash, `.claude/hooks/lib/gaia-packages.sh`, for hooks and guard scripts. Node scripts outside the CLI, such as the determinism classifier, read the registry through it rather than carrying a reader of their own.
- TypeScript, in the CLI source, for the CLI (scaffolds, wiki tooling, settings sync).

Consumers include the TDD classifier ([[Determinism Classifier]]), the RED gate ([[TDD RED Verification]]), the worthiness gate ([[Worthiness Presence Gate]]), the pre-commit plan ([[Pre-commit Hooks]]), and the wiki dead-path scan.

## Fail-closed rule

A guard never guesses a layout. An absent registry means the built-in default registry (`web` at `apps/web/`), never a built-in descriptor. A registry or descriptor that is present but malformed, a descriptor that is missing (including `apps/web/gaia.package.json` under the built-in registry, whose error names the restore command), or a missing `jq` makes the reader return a non-zero status and a one-line `gaia-packages:` error with a next step, and every query then answers as if nothing were loaded. Each guard maps that to its own safe direction: a refusal set refuses everything, a gate blocks, a classifier denies. A path no registered member owns is not in scope for a package guard; the root-level arms of each guard still apply. A workspace member that is not registered is never an error: no structure check fails a customized project, and fitness only warns.

## Launch scope

Harness workflows run from a root launch. An `apps/web/` launch supports frontend work through commit: it loads `apps/web/CLAUDE.md`, the frontend rules and skills, and the generated `apps/web/.claude/settings.json`. That scope covers web-stack members and members that opt in with `generatedSettings`. The root settings reach such a member only through `gaia packages sync-settings`, which regenerates its file from the root file plus `<member>/.claude/settings.overlay.json`; run it after any change to the root `.claude/settings.json`. `.gaia/scripts/check-settings-drift.sh` fails the commit when the two disagree.

Every other registered member carries a warning stub instead: a settings file that tells a session launched there to work from the root, restores no guard, and is never written over a settings file you wrote by hand.

## Adding an app or package

One procedure for every new workspace member. Apps go in `apps/<name>`, libraries in `packages/<name>` once two consumers share them, never a new top-level folder. Each member needs three things, each named here:

1. **Workspace entry.** `pnpm-workspace.yaml` already lists `apps/*` and `packages/*`, so a folder under either joins by having a `package.json`. A member elsewhere (an adopter's `infra`, say) needs its own line under `packages:`.
2. **Registry entry.** Add `{name, path}` to `.gaia/packages.json`, keeping the `web` entry. The `name` equals the descriptor's `name`.
3. **Descriptor.** Write `<member path>/gaia.package.json` with `schemaVersion`, `name`, every `globs` key (empty lists are fine) and, for a React app, `"stack": "web"`. Land the registry entry and descriptor in one commit: a registered member with no descriptor fails closed.

Then the member runs through the root gate: root `typecheck` and `lint` run each member's script of that name, and `test:ci` runs member suites one at a time. `bash .gaia/scripts/gate-member-warnings.sh` prints a warning for a member that has tests but no `test:ci`, or TypeScript but no `typecheck`.

### Example: a second app sharing strings

A second app, `apps/admin`, needs the same translation strings as `apps/web`. Move them into a library, `packages/i18n`:

1. Workspace entry: nothing to add, `packages/*` is already listed. Give `packages/i18n` a `package.json`.
2. Registry entry: add `{"name": "i18n", "path": "packages/i18n"}` to `.gaia/packages.json`.
3. Descriptor: `packages/i18n/gaia.package.json` with no `stack`, so it is a library, not an app.

Both apps depend on it with `"i18n": "workspace:*"`. The same three things register `apps/admin` itself, with `"stack": "web"` in its descriptor.

### Example: the same tokens in two apps

Design tokens shared by two web apps follow the same route through `packages/design-tokens`: a `package.json`, an entry in `.gaia/packages.json`, and a `packages/design-tokens/gaia.package.json`. Tokens here are CSS custom properties, so they reach web apps only and cannot reach React Native, which has no CSS. A React Native app needs the values exported as JavaScript instead.

### Things a new member must also settle

- **Roster.** A member under `apps/` or `packages/` is already claimed by the default audit member. A member outside both needs a roster claim for the default member in `.gaia/audit-ci.yml`, or `bash .gaia/scripts/verify-audit-roster.sh` reports its files unowned.
- **Build output.** The root `.gitignore` has no rule for a member's build output. Give the member its own `.gitignore`.
- **Libraries.** A library exports its source, or builds before the consumer's typecheck runs. Pick one; a library whose `main` points at output nobody built breaks the first typecheck.
- **Docker.** The stock `apps/web/Dockerfile` copies only the app, so a member that consumes a workspace library extends the Dockerfile to copy that library's `package.json` and source.
- **Root `CLAUDE.md`.** A second web-stack member adds its own Read line to the root `CLAUDE.md`, the way the `apps/web/` line does, so a root session loads its rules.

See also [[Claude Hooks]] and [[Folder Structure]].
