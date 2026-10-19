### Phase 0: Override audit

Each key in the top-level `overrides:` map in `pnpm-workspace.yaml` exists for one of two reasons: to resolve a **peer-dependency conflict**, or to enforce a **security floor** (pin a transitive dependency at or above a patched version to clear a known advisory). The two are detected by different tests, and an override is obsolete only when removing it regresses **neither**. A peer-dep test alone is blind to security-floor pins (a CVE pin never produces a peer-dep error), so it would wrongly delete every one of them.

**Capture the advisory baseline first**, with every override still in place:

```bash
mkdir -p .gaia/local/cache/shared
audit_baseline="$(mktemp .gaia/local/cache/shared/.override-audit-baseline.XXXXXX)"
audit_now="$(mktemp .gaia/local/cache/shared/.override-audit-now.XXXXXX)"
bash .gaia/scripts/override-audit-advisory-ids.sh "$audit_baseline"
```

Each line is one advisory ID; this file is the set of advisories the current overrides tolerate. Shell variables do not survive between Bash tool calls, so carry both paths yourself, and remove both files when the audit ends.

**A non-zero exit means `pnpm audit` did not answer** (offline, rate limit, registry outage), and the script prints the reason on stderr. An unanswered audit is not an empty advisory set: diffed against it, no removal ever introduces an advisory, so every security floor would read as obsolete. If the baseline capture exits non-zero, do not run the loop below: remove no key, change nothing, and note the audit as **Not run (pnpm audit unavailable: <reason>)**, then remove both files.

Then, for each override key, one at a time, leaving every other `pnpm-workspace.yaml` setting untouched:

1. Temporarily remove that single key from the `overrides:` map.
2. Run `pnpm dedupe`. A bare `pnpm install`, even `pnpm install --force`, short-circuits with "Already up to date" when only the `overrides:` map changed and leaves the lockfile untouched, so the toggle would not re-resolve and the test below would read the stale tree; `pnpm dedupe` performs a full install that re-resolves and applies the override change. See `wiki/dependencies/pnpm-overrides.md`. If it exits non-zero, restore the key, note as **retained (install error)**, and move to the next key, do not diagnose the failure or run the tests below for this key.
3. **Peer-dep test:** run `pnpm ls 2>&1` and scan for peer-dep errors.
4. **Security-floor test:** capture the advisory IDs the same way. Any ID present now but absent from `$audit_baseline` means removing this override reintroduced a known vulnerability.

   ```bash
   bash .gaia/scripts/override-audit-advisory-ids.sh "$audit_now"
   comm -13 "$audit_baseline" "$audit_now"   # IDs this removal introduced
   ```

   If the capture exits non-zero, run no `comm` and do not decide this key: restore it, run `pnpm dedupe`, and stop the loop. This key and every key not yet tested are **retained (pnpm audit unavailable: <reason>)**; keys already decided keep their verdicts, since each was tested against an audit that answered. Continue with the lockfile assertion below.

5. Decide:
   - Peer-dep errors **or** any newly introduced advisory → the override is load-bearing. Restore the key. Note as **retained** (record which test failed, and the advisory ID + package if it was the security-floor test). A retained security floor names its advisory by GHSA id when it has one, else by pnpm id: for a floor the run's security phase added, the id the orchestrator passed with it; otherwise the reintroduced record's `github_advisory_id`, falling back to its pnpm advisory id.
   - Neither regressed → the override is obsolete. Leave it removed. Note as **removed**.

The security-floor test is **severity-agnostic on purpose**: an override is a deliberate maintainer artifact, so any advisory it was silencing, at any severity, is reason to keep it. This is stricter than the high/critical floor in `wiki/dependencies/pnpm-audit.md` (Noise scoping): deleting a maintainer's pin warrants more caution than surfacing an advisory.

**After the toggle loop, assert the lockfile matches config.** Once every retained key is restored, the lockfile's top-level `overrides:` block must list exactly the keys present in the `overrides:` map in `pnpm-workspace.yaml`. Compare the two; on any drift (a config key missing from the lockfile block, or vice versa) the floor is unapplied, so run `pnpm dedupe` once more and re-run the quality gate. This assertion guarantees that every retained floor is applied, never silently disabled. It says nothing about whether a floor is current. Note the tradeoff: `pnpm dedupe` re-optimizes the whole tree, so a single toggle can yield a wider lockfile diff than the one key it touched (it may also drop now-redundant transitives). That broader diff is expected, and correct, the alternative is an unapplied override.

### Quality gate

```bash
pnpm typecheck
pnpm lint
pnpm test --run
pnpm pw
pnpm build
```
