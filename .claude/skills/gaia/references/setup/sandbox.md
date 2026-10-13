# Sandbox decision

`/setup-gaia` Phase 2 reads this file, whole, when its sandbox gate says the decision is owed (no recorded resolution, or `--reconfigure`), and also when the decision is already settled but has no record, to run `## Record a settled decision` alone. For an owed decision, run the four steps below in order, then the honesty message on the enable path; control returns to Phase 2 of `setup-gaia.md`, which continues to Phase 3.

The marker `.gaia/local/sandbox.json` governs the decision; the `sandbox` record only says it was made. Each outcome below records once its marker is written, and a failed command records nothing.

1. **Read the recommendation.** Absent file, absent key, or an unreadable config all mean "no recommendation", so the default is off:

   ```bash
   RECOMMENDED="$(jq -r '.sandbox_recommended // false' .gaia/project.json 2>/dev/null || echo false)"
   ```

2. **Classify capability** via the injectable CLI (falls back to a real host probe when flags are omitted):

   ```bash
   .gaia/cli/gaia sandbox detect --json
   ```

   Cache `capability`, `installCommand`, `reason` from the JSON.

3. **Branch on capability.** Never half-enable: the sandbox is either fully applied or left off.
   - `unsupported` (native Windows or WSL1): do NOT enable. Tell the developer plainly that Claude Code's OS-level sandbox is unavailable on this machine (use `reason`) and point them to WSL2 instead. Record the outcome and skip the prompt:

     ```bash
     .gaia/cli/gaia sandbox record --outcome incapable --capability unsupported
     .gaia/cli/gaia setup record sandbox not-applicable
     ```

   - `needs-deps` (Linux/WSL2 missing bubblewrap/socat): do NOT enable, do NOT half-enable. Print the concrete `installCommand` (plus the Fedora form carried in `reason`) and tell the developer the sandbox stays off until those are installed and `/setup-gaia` is re-run. Record the outcome and skip the prompt:

     ```bash
     .gaia/cli/gaia sandbox record --outcome incapable --capability needs-deps
     .gaia/cli/gaia setup record sandbox not-applicable
     ```

   - `ready` (macOS Seatbelt, or Linux/WSL2 with both deps present): run the single prompt below.

4. **The single informed prompt** (`ready` only). Use AskUserQuestion exactly once, there is no promptless auto-enable branch anywhere in this file. Its default option tracks `RECOMMENDED`: when `true`, "Enable the sandbox" is Recommended; when `false` (including when nothing was recommended), "Don't enable" is Recommended.

   > Enable Claude Code's OS-level Bash sandbox on this machine? It sandboxes Bash commands and their child processes, but it can break local tools: `docker`, `gh`, `terraform`, and other commands that need network or host access may fail or need allowlisting. Your project owner {recommends / does not recommend} it; each machine decides for itself.
   >
   > - **Enable the sandbox** / **Don't enable** (Recommended tracks the owner's recommendation, default off when none)

   On **enable**:

   ```bash
   REGISTRY="$(npm config get registry 2>/dev/null)"
   DOCKER_PRESENT=false; command -v docker >/dev/null 2>&1 && DOCKER_PRESENT=true
   .gaia/cli/gaia sandbox apply --registry "$REGISTRY" --docker-present "$DOCKER_PRESENT" --capability ready && .gaia/cli/gaia setup record sandbox applied
   ```

   `apply` deep-merges the minimal seed into `.claude/settings.local.json` (gitignored) and writes the `enabled` marker. Then print the honesty message below. Tell the developer the enable takes effect on the NEXT Claude Code session (this setup run stays unsandboxed), matching the existing "restart Claude Code" closing line in Phase 6.

   On **don't enable**:

   ```bash
   .gaia/cli/gaia sandbox record --outcome declined --capability ready
   .gaia/cli/gaia setup record sandbox declined
   ```

**Sandbox honesty message.** Print this on the enable path above:

> Note: enabling the sandbox alone does not protect .env. The sandbox's default read policy is permissive (it still reads ~/.aws, ~/.ssh, .env). What protects `.env` is GAIA's committed `sandbox.filesystem.denyRead` entries, which reach subprocesses spawned by sandboxed Bash and cover `.env`, the `.env.local` / `.env.production` variant family, and the key, certificate, credential, and secrets-directory classes, each at any depth in the project rather than at its root only; `.env.example` stays readable. They do NOT cover MCP shell execution, NOT a `docker *`-excluded command that runs outside the sandbox, and NOT `~/.ssh` or `~/.aws`: no entry names either one, and an ordinary private key there (`id_rsa`, `id_ed25519`) carries none of those names or extensions and sits under no `secrets/` directory, so it stays readable. The same denied read also blocks the app's own `.env` reads under Claude-run tooling (Vite, tests). And if bubblewrap/socat later goes missing, an enabled machine degrades to unsandboxed by default, at which point only the `block-sensitive-read.sh` tool-tier guard remains.
>
> The minimal seed itself only adds the registry host to `allowedDomains` and, when docker is present, a `docker *` exclusion. It still leaves `gh`/git-over-https, `uvx`, `curl`, and claude plugin installs BLOCKED until you allowlist them yourself.

## Record a settled decision

Run when the marker already holds a decision and `sandbox` is owed: it records what the marker says, with no question.

```bash
OUTCOME="$(.gaia/cli/gaia sandbox status --json 2>/dev/null | jq -r '.outcome // empty' 2>/dev/null)"
case "$OUTCOME" in
  enabled) .gaia/cli/gaia setup record sandbox applied ;;
  declined) .gaia/cli/gaia setup record sandbox declined ;;
  incapable) .gaia/cli/gaia setup record sandbox not-applicable ;;
  *) echo "The sandbox marker holds no outcome; nothing recorded." ;;
esac
```
