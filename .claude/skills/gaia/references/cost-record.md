# Cost record (run end), shared record recipe

Shared run-end cost record for the interactive GAIA command skills. A skill applies it from its own `## Cost record (run end)` section, substituting `{{COMMAND}}` with the command name (e.g. `gaia-debt`, `gaia-codify`). The skill keeps its own `## Cost record (run end)` heading and its run-ending-paths bullets inline (those are command-specific and anchor the `(Run ends here; see \`## Cost record (run end)\`.)` callbacks); this reference owns only the record call and the reporting rules below.

Standalone final step, one call:

```bash
bash .gaia/scripts/usage.sh record command:{{COMMAND}} --workflow {{COMMAND}}
```

**Artifact pass-through.** When this run opened a pull request and the URL `gh pr create` printed appeared in this run's own Bash tool result, and the pull request is on the current repo, append:

```bash
  --pr <N>
```

Take `<N>` only from that printed URL (a ref carries no repo, hence the current-repo condition). Without one, pass no `--pr`: the record correctly carries no artifact, and that is not an error.

**A run continued from another session.** Its continuation prompt carries a `usage.sh join` line. If this session has not run it yet, run it before the record call, so the Cost line covers every session of the run.

**Report the line verbatim.** On exit 0 the first stdout line is the Cost line, e.g. `Cost: 5.2M tokens, $4.12, 6m39s`, and a `Note:` line under it says when the figure may be low or a minimum. Relay the Cost line and its `Note:` lines, unchanged and unfenced, as the last of the run's report; do not reassemble, reformat, or re-derive them. On a non-zero exit nothing was recorded and no Cost line prints: relay the one stderr line in its place.

The record never blocks and never turns a failed run into a successful one: a non-zero exit is reported, not retried, and does not change the run's outcome. On a path that ends in an error (a rejected push, a blocked merge), record the cost, then report the failure exactly as before; recording the cost never implies success.
