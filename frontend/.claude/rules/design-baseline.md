---
paths:
  - 'app/styles/**'
  - 'app/components/**'
  - 'app/pages/**'
---

# Design Baseline (Neutral, Not a Design System)

The visual styling GAIA ships in `app/styles/`, `app/components/`, and `app/pages/` is a **deliberate neutral baseline**. It carries no brand hue and no opinion the adopter must follow. It is not a chosen design system.

## The token values are a placeholder

The role-token values in `app/styles/theme.css` are shadcn's neutral placeholder, not a brand choice. Three of them carry an accessibility override, a contrast fix rather than a design decision: `--muted-foreground` and `--destructive` are darkened in the light theme so text passes 4.5:1, and `--ring` is overridden in both themes so the focus indicator reaches 3:1. Keep those fixes when an adopter replaces the placeholder values, or re-measure. The contract for using tokens (role tokens only, when a new color needs approval) lives in `frontend/.claude/rules/tailwind.md`; this rule only governs whether Claude may choose or change values.

## Behavioral switch

`wiki/concepts/Design System.md` carries a machine-readable sentinel in its frontmatter:

```
established: false
```

**While `established: false`:**

- Use the existing role tokens (the contract is in `frontend/.claude/rules/tailwind.md`). Ask the adopter before choosing brand values, changing a token value, or restyling a component.
- Treat the token values, font stack, spacing and radius as a blank slate: ask the adopter rather than extrapolating a house style, palette, type scale or color pairing from them.

**Once an adopter records a real design system** (`established: true` in `wiki/concepts/Design System.md`), read that page for their chosen decisions and follow it instead.

## When Claude is implementing design decisions

If the adopter directs Claude to make styling changes that represent real brand decisions -- a chosen palette, a brand hue replacing the neutral placeholder values, a specific type stack -- treat updating `wiki/concepts/Design System.md` as part of the same task:

1. Document the decisions in the wiki page body (what was chosen and why, replacing the placeholder prose).
2. Flip `established: true` in the wiki frontmatter.
3. Update `updated` in the wiki frontmatter to today's date.

Do this regardless of how the design was arrived at: Figma handoff, verbal direction, a style guide, a design token file. The wiki update is part of completing the task, not a separate follow-up.

### When the adopter defers the choice

If the adopter hands the choice to Claude ("you decide", "pick something") rather than directing it, avoid these default styles: a cream or off-white background, italic accent words in headings, numbered "01 / 02 / 03" section labels, monospace text used as decorative labels, pill-shaped buttons as the default shape, and purple or violet gradients. A general instruction to avoid a generic look only swaps one default for another, while naming the patterns steers away from them. Whatever gets picked instead is still a design decision, so the wiki update above still applies.
