---
type: dependency
status: active
package: node-html-parser
role: html-parsing
created: 2026-11-04
updated: 2026-11-04
tags: [dependency, testing]
---

# node-html-parser

Dev-only HTML parser. It reads rendered markup in real-server Playwright tests that use the `request` fixture, so a test checks a server-rendered page's status and heading with no browser page.

Used by `apps/web/.playwright/html.ts`, whose `parseHtml` returns the parsed nodes and holds no assertions. The pattern for request-only checks is in `apps/web/.claude/rules/playwright.md`.
