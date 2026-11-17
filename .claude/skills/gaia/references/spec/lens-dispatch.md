# Lens dispatch

How one adversarial audit lens is dispatched and how its output is trusted. Read whole by `/gaia-spec` step 7 and `/gaia-plan` step 4.6 before dispatching lenses. The caller's playbook owns lens selection, refutation, and disposition; this file owns only the preamble every lens receives, the file it writes, and the classification that stops a silent lens from passing as clean.

Contents: `## Caller slots`, `## Shared preamble`, `## Write and return`, `## Findings file schema`, `## Pre-clear, classify, re-dispatch`.

## Caller slots

Each caller fills the `<...>` placeholders of the shared preamble from its own column. Findings are graded on three tiers, each defined by the action it requires:

- **Critical:** wrong, or will produce broken work; must be fixed before the gate.
- **Major:** a significant gap or defect; fix, or a human decides (acknowledge).
- **Minor:** real but small; fix by default, never ignorable.

There is no tier below Minor: what is worth reporting is Minor, what is not is not reported.

| Slot | Spec audit | Plan audit |
| --- | --- | --- |
| Artifact under audit (`<ARTIFACT>`) | the working draft at `<DRAFT_PATH>` (spec `<spec_id>`) | the plan in `<PLAN_DIR>`: `<PLAN_DIR>/README.md` plus every `<PLAN_DIR>/task-*.md` |
| First Read | `<DRAFT_PATH>` | `<PLAN_DIR>/README.md` (the task graph and frozen interface contracts), then every `<PLAN_DIR>/task-*.md` |
| Defect target | a flawed plan or implementation downstream | a broken or conflicting orchestrator result |
| Evidence form | SPEC section or flow id, plus `file:line` | task doc plus `file:line` |
| `location` meaning | SPEC section or flow id | task doc or README section |
| Findings directory (`<FINDINGS_DIR>`) | `.gaia/local/cache/audit-<spec_id>/findings/` | `<PLAN_DIR>/audit/` |
| Write tool | the ordinary write tools | `Bash` at the main-checkout path when the session runs in a linked worktree, reading the file back to confirm its content and location before it is classified, the edit tools otherwise |
| `critical` | the SPEC is wrong or will produce broken or misleading work; fix before gate 2 | the plan is wrong or will produce broken or conflicting work; fix before execution |
| `major` | a significant gap or ambiguity a planner is forced to guess on; fix, or the human decides | a significant gap or hidden dependency the orchestrator is forced to guess on; fix, or the human decides |
| `minor` | real but small; fixed by default | real but small; fixed by default |

A plan written from a spec is audited by `plan/decomposition-audit.md` (the plan's own decomposition audit), not by a re-run of the SPEC audit.

Plan write tool: `<PLAN_DIR>` is a main-anchored absolute path (stored in the main checkout: the clone's primary working directory, on any branch). When the session runs in a linked worktree, the harness refuses `Edit` and `Write` at that path, so the lens agent, and the main thread's inline fallback, write the findings file with `Bash` at the main-checkout path and read it back to confirm both its content and its location before it is classified. Keep the fallback to the findings files: a `Bash` redirect is never the way to write into another checkout where the edit tools already work; use the edit tools there.

## Shared preamble

Send this to every lens, interpolating the slots. The caller appends a `LENS: <name> (id prefix <ID>)` line and the lens's focus text from its own playbook.

> You are an ADVERSARIAL auditor of <ARTIFACT>. Repo root is `<repo_root>`; you may read any file under it, including `node_modules`. Your job is to find DEFECTS that would cause <defect target>, not to praise the artifact.
>
> Lead with a tool call, not prose: your first action is a Read of the artifact under audit (<first Read>), and you emit your structured result before any prose.
>
> - Verify EVERY checkable claim against the actual repository and `node_modules`. Do not take the artifact's assertions on faith; when a claim names code, a file, an export, or a signature, open it and confirm it resolves.
> - Cite evidence: <evidence form> for any ground-truth check.
> - Severity: `critical` = <critical meaning>; `major` = <major meaning>; `minor` = <minor meaning>. A finding between major and minor is graded by those definitions, major when unsure.
> - Give each finding a stable id prefixed with your lens code.
> - Where the SPEC or a document its Required reading names conflicts with a check the scaffold ships (a security refusal or validation), propose only the narrowest repair that satisfies what they state, keeping the rest of the check: when the start command those documents give supplies no session secret, an unset one may fall back to a strong per-process random value the app logs at startup (sessions then reset on restart and are not shared across instances), while a set value under 32 characters is still refused. A check they are silent on is never removed.
> - Be concrete and falsifiable. A finding a verifier can refute by reading one file is a good finding; vague "could be clearer" is not.
> - **Write** your full findings to `<FINDINGS_DIR><LENS>.json` (the fully qualified path) under the file schema, using <write tool>. Write the file even if your findings array is empty.
> - **Return** only the short summary, no finding bodies.

The preamble, the `LENS:` line and the focus text are rendered to a brief file by `node .gaia/scripts/spec/lens-brief.mjs lens ...` (with the output-format clause of `## Findings file schema` appended), never pasted into the Agent call: each Agent call carries only the short prompt that command prints. A refuter brief is rendered by `lens-brief.mjs refuter ...` from the caller's refuter prompt. The command reads the templates below and fills `<name>`, `<ID>`, `<audit>` (`SPEC` or `plan`) and `<brief path>`.

Lens short prompt:

> You are the <name> (<ID>) lens of the <audit> audit. Your first action is a Read of <brief path>; follow it. Where it says your first action, it means your first action after that Read.

Refuter short prompt:

> You are a refuter in the <audit> audit. Your first action is a Read of <brief path>; follow it. Where it says your first action, it means your first action after that Read.

Verification lens line, one per verification lens a Deep refuter works through (in the order `correctness`, `security/safety`, `reproduces-as-described`), prepended to that refuter's prompt:

> Verification lens: <verification lens>

Batched refuter instruction, appended to a batched refuter's prompt:

> Verify every listed finding id, write one verdict file per id at the listed paths, and return a JSON array of thin verdict lines, one per id.

## Write and return

The agent, or the main thread running a lens inline, writes `<FINDINGS_DIR><LENS>.json` at its fully qualified path, even when the array is empty. The file on disk is what the caller trusts; the reply is a short summary of it.

The reply is the short summary and nothing else. It lists every finding, material and minor, as `{ id, severity, title }`:

    { "dimension": "<lens>", "counts": { "critical": <int>, "major": <int>, "minor": <int> },
      "findings": [ { "id": "<lens>-NNN", "severity": "...", "title": "..." } ] }

Whether the main thread later reads a finding body is the caller's rule: the spec audit keeps bodies out of the main thread, and the plan audit's main thread reads the files to apply fixes.

## Findings file schema

What each agent writes to `<LENS>.json`. This is not a return contract; the short summary above is what flows back. `brief_token` is required on the file of a briefed lens (a missing or wrong token classifies as a no-op); every other added field is optional.

    {
      "dimension": "<lens name>",
      "brief_token": "<the 32-hex token from the lens's brief>",
      "findings": [
        {
          "id": "<lens-prefix>-NNN",
          "severity": "critical" | "major" | "minor",
          "title": "<short>",
          "location": "<per the caller's location slot>",
          "issue": "<one sentence: what is wrong>",
          "evidence": "<file:line or artifact quote actually checked>",
          "recommendation": "<one sentence: the fix>",
          "proposed_disposition": "plan_directive" | "spec_defect"      (SPEC lenses)
                               | "apply" | "structural",                (plan lenses)
          "directive": "<final plan-time directive wording, one line>", (SPEC lens, only with plan_directive)
          "row_patches": [ <row patch> ],                                (plan lens, only on a fix it recommends applying)
          "replacements": [ { "file": "<task-<name>.md | README.md | ORCHESTRATOR.md>", "old": "<exact text>", "new": "<text>" } ]
        }
      ]
    }

A row patch is a field delta keyed by row id:

    { "op": "add",    "row": { <full tests.json row, id included> } }
    { "op": "change", "id": "T7", "set": { "<field>": <new value>, ... }, "expect": { "<same fields>": <prior value>, ... } }
    { "op": "remove", "id": "T7", "expect": { "file": "...", "title": "...", "security": "..." } }
    { "op": "sets",   "entry": { <full tests.json sets entry> }, "expect": { <the entry it replaces> } | null }

`expect` names every field `set` changes, `null` for a field the row does not have yet (the `caseKinds` a flagged keyless row needs); a `change` with no `expect`, or whose `expect` misses a `set` field, is malformed.

A `sets` patch adds its entry when `expect` is `null`, and otherwise replaces the entry equal to `expect`. A fix that writes or completes an entry carries, in the same finding, the `add` or `change` patches that give each row the entry lists its `cells`: the entry and its cells pass the set-cell check only together.

The output-format clause is appended to every lens brief in the part for its kind, with `<BRIEF_TOKEN>` filled by a fresh token and, in the SPEC part, `<DIRECTIVE_RULES>` filled at render time from the Plan-time directive bullet of `spec/audit.md` `## 7c` (from `Write it as the property a test proves` to the end of the bullet).

Output-format clause, SPEC part:

> After your first Read, read the `## Findings file schema` section of `.claude/skills/gaia/references/spec/lens-dispatch.md` for the file's shape. Set `proposed_disposition` on each finding: `plan_directive` when the SPEC's binding contract (its flows, success criteria and intent) is already correct and only the implementation needs steering, `spec_defect` when a flow, a success criterion or the intent itself is wrong, gameable, or missing. Write `directive` only on a finding you propose as `plan_directive`, in its final wording, on one line. <DIRECTIVE_RULES>
>
> Write `"brief_token": "<BRIEF_TOKEN>"` at the top level of your findings file, beside `dimension`.

Output-format clause, plan part:

> After your first Read, read the `## Findings file schema` section of `.claude/skills/gaia/references/spec/lens-dispatch.md` for the file's shape and the row patch and replacement shapes. Set `proposed_disposition` on each finding: `apply` when its fix is a concrete edit to the plan's files, `structural` when it needs a decision or a rework no exact edit states. Write `row_patches` and `replacements` only on a fix you recommend applying; leave them off otherwise.
>
> Write `"brief_token": "<BRIEF_TOKEN>"` at the top level of your findings file, beside `dimension`.

## Pre-clear, classify, re-dispatch

An absent report reads as "the lens found nothing", the conclusion a silent lens must not earn. The rule is `.claude/rules/subagent-dispatch.md`; the steps for a lens:

1. Before dispatch, clear the file of every lens about to be dispatched; rendering a lens's brief pre-clears that brief. Spell the commands repo-relative so the existing allow patterns match, never with the absolute `<PLAN_DIR>` spelling:
   - Spec: `rm -f .gaia/local/cache/audit-<spec_id>/findings/<LENS>.json`
   - Plan: `rm -rf .notebook/plans/<PLAN-NNN>/audit`, then `mkdir -p .notebook/plans/<PLAN-NNN>/audit` (a spec-derived plan: `rm -rf .notebook/specs/<SPEC-ID>/plan[-N]/audit`, then `mkdir -p .notebook/specs/<SPEC-ID>/plan[-N]/audit`)
2. Dispatch every lens in one message, one Agent call per lens, each a `general-purpose` Agent whose prompt is the short prompt `lens-brief.mjs lens` printed for it.
3. After each agent's completion notification, never at the moment the dispatch call returns (that call reports dispatch metadata before the agent has run), classify its file:

   ```bash
   node .gaia/scripts/spec/lens-brief.mjs classify --findings <findings file> --brief <brief file>
   ```

   Exit 0 is real (an empty `findings` array is real), 1 is a no-op (a missing file, a missing `findings` key, or a missing or wrong `brief_token`), 2 is a usage error: a caller bug, so stop and surface it.
4. On a no-op, re-clear that lens's file and re-dispatch that lens exactly once; re-rendering its brief issues a fresh token.
5. On a second consecutive no-op, run that lens inline on the main thread and write its file yourself, reading the brief and writing its token too, then continue. Say in one line which lens ran inline.
