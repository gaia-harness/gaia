---
paths:
  - 'app/routes/**/*'
  - 'app/pages/**/*'
  - 'app/root.tsx'
  - 'app/middleware/**/*'
  - 'react-router.config.ts'
---

# React Router Docs

For React Router framework-mode work, read the docs shipped with the **installed** React Router, not the web; they match the pinned version (7.17.0+ ships them as markdown):

```bash
ls frontend/node_modules/react-router/docs   # explanation/ how-to/ start/ upgrading/ index.md
```

Reach for the online docs (`reactrouter.com/docs`) only when the local copy is absent (older React Router) or a topic is missing.

When a loader, action, or middleware tempts a hand-rolled server-side primitive (csrf, honeypot, safe-redirect), check the remix-utils decision map at `wiki/dependencies/remix-utils.md` before reinventing; remix-utils ships these as audited utilities.
