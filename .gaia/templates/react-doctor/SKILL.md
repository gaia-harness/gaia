---
name: react-doctor
description: Use when finishing a React feature, fixing a React bug, or before committing React code, to check the react-doctor score did not regress. Also for a full React health scan, a focused UI design audit, a runtime trace of a slow React interaction, or explaining and tuning react-doctor rules.
---

# React Doctor

Scans React code for security, performance, correctness, accessibility and architecture issues, and scores it 0-100. GAIA pins the version every command below runs.

## After changing React code

```bash
npx -y react-doctor@{{REACT_DOCTOR_VERSION}} --verbose --scope changed
```

Check the score did not regress. If it dropped, fix the regressions before committing.

## Full scan

```bash
npx -y react-doctor@{{REACT_DOCTOR_VERSION}} --verbose
```

For general cleanup. Fix errors first, then warnings.

## UI design audit

```bash
npx -y react-doctor@{{REACT_DOCTOR_VERSION}} design --verbose
```

Runs only the design-tagged rules (composition, typography, interaction, accessibility, motion), including ones a general scan leaves opt-in.

## Runtime performance

For a vague "feels slow" or "janky" report, run this in an interactive terminal:

```bash
npx -y react-doctor@{{REACT_DOCTOR_VERSION}} scan <url> --format json
```

It opens an isolated Chrome profile, records a DevTools trace while the user reproduces the slow interaction, and stops when they press Enter. Read the structured summary first, then the local `.json.gz` trace for CPU, browser and React component evidence. For authenticated state, pass `--cdp <remote-debugging-url>` to a Chrome already running with remote debugging. Never ask for cookies or copy the user's browser profile. The trace is sensitive local data: never upload it without explicit permission. For a known re-render problem, use the `gaia-react-perf` skill instead.

## Explaining or tuning rules

When the user wants a rule explained, disagrees with one, or wants to change which rules run (not fix code), read [references/explain.md](references/explain.md) and follow it.

## Flags

| Flag | Purpose |
|---|---|
| `.` | Scan the current directory |
| `--verbose` | Affected files and line numbers per rule |
| `--scope changed` | Only issues introduced vs the base branch (default: full) |
| `--scope contextual` | Findings in modified functions, JSX elements or files, as each rule selects |
| `--scope lines` | Only issues on changed lines |
| `--score` | Only the numeric score |
| `design` | Only the focused UI design rules |
