# code-audit-frontend Extensions

This directory contains library-specific audit rules for the `code-audit-frontend` agent (`.claude/agents/code-audit-frontend.md`). The extension mechanism is part of a broader Claude-integration convention documented in `wiki/concepts/Claude Integration Conventions.md`.

## How it works

At startup the agent lists the `*.md` files in this directory (skipping this README) and reads each one's `subagents:` line with one command. It does not read the file bodies: each specialist is handed the absolute paths of the files that list its role and Reads them itself.

If this directory is empty or missing, the agent reports an error finding naming it rather than reviewing without the library rules (Extension Loading in `.claude/agents/code-audit-frontend.md`).

## Extension file format

```yaml
---
subagents: [react-patterns, typescript, translation]
library: package-name
---
```

Valid `subagents` values map to the three specialist roles of the `audit-rule-specialist` type:

- `react-patterns`: `.tsx` files (hooks, components, accessibility)
- `typescript`: `.ts` and `.tsx` files (types, architecture, conventions)
- `translation`: changed language files and files with an i18n call signal

These values are **rule-injection labels** (metadata selecting which specialist receives this file's rules), NOT skill or command names. The agent dispatches each specialist with the Agent tool, naming the `audit-rule-specialist` type, never via the Skill tool, and there is no `subagent:<name> files:<paths>` argument string.

The supported shape is a flow list on one line: `subagents: [react-patterns, typescript]`. Any other shape (a block list, or no `subagents:` line) is reported as an error finding naming the file.

`library` is documentation only, it identifies which dependency this file covers.

## When to update

| Event                                                                           | Action                                              |
| ------------------------------------------------------------------------------- | --------------------------------------------------- |
| Add a library with audit-worthy patterns (form validation, styling, i18n, etc.) | Create a new extension file                         |
| Remove a library                                                                | Delete its extension file                           |
| Replace a library (e.g. Conform → react-hook-form)                              | Delete the old file, create one for the replacement |
| Library has a major API change that invalidates its rules                       | Update the file                                     |

## Current extensions

List this directory; each file's frontmatter names its library and subagents.
