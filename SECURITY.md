# Security Policy

## Reporting a vulnerability

Report vulnerabilities privately through GitHub's [private vulnerability reporting](https://github.com/gaia-harness/gaia/security/advisories/new). Do not open a public issue, discussion, or pull request for a suspected vulnerability.

Include:

- The affected GAIA version (`.gaia/VERSION` in your project).
- What an attacker controls and what they gain.
- Steps to reproduce, ideally a minimal project or input.
- A suggested fix or mitigation, if you have one.

## Supported versions

Security fixes land in the latest release only; they are not backported to older versions. If you are on an older version, upgrade with `/update-gaia` to receive the fix.

## What to expect

- Acknowledgment within 7 days.
- An assessment of whether the report is in scope, and its severity.
- A fix in a patch release, then a published GitHub Security Advisory (with a CVE where warranted).

GAIA is maintained by one person, so timelines beyond acknowledgment are best effort. There is no bug bounty.

## Scope

GAIA is a harness that gives Claude Code shell access, hooks, and scripts in your project by design. A vulnerability is a way for **untrusted input** to cause behavior the user did not intend.

In scope:

- A hook, script, or CLI command that executes or injects untrusted input, such as a branch name, commit message, issue or PR body, file name, or dependency metadata.
- A GitHub Actions workflow GAIA ships that is open to script injection, privilege escalation, or secret exposure.
- A guard or gate that can be bypassed so that a protected action runs without the confirmation it requires.
- Supply-chain weaknesses in how GAIA is released or how `/update-gaia` fetches and applies updates.
- Secrets or credentials exposed by GAIA's own code or defaults.

Out of scope:

- Claude running commands or editing files you asked it to, or that your permission mode allows.
- Prompt injection that only succeeds when the user approves the resulting action.
- Vulnerabilities in your own application code, or in third-party dependencies with no GAIA-specific exploit path (report those upstream).
- Automated scanner output without a demonstrated impact.
- The marketing and docs websites (gaiaharness.com, docs.gaiaharness.com), unless the issue affects GAIA users directly.

## Disclosure

We follow coordinated disclosure: please give us a reasonable chance to release a fix before discussing the issue publicly. Once the fix ships, the advisory is published and reporters are credited by name, or anonymously, as they prefer.
