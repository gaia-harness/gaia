/**
 * The frozen provenance marker `/gaia-codify` writes into a promoted rule.
 *
 * Single source of truth for the marker text. Both binders (the
 * `covered-classes.ts` `MARKER_RE` and `/gaia-cleanse`'s recognition of
 * provenance-marked rules) are prefix-bound and tail-agnostic, so a rule
 * promoted under an earlier tail keeps its never-prune-for-non-recurrence
 * guardrail. The doc copies (`codify.md` template + frozen-marker section,
 * `cleanse/research.md`, and `wiki/concepts/Policy-Memory Loop.md`) reproduce
 * `markerComment(...)` byte for byte so the head never drifts.
 */

/** The prefix the covered-classes binder matches; also the stable head of the doc copies. */
export const MARKER_PREFIX =
  'gaia-harden: promoted from recurring finding_class';

/** The full, frozen provenance-marker comment for a given finding_class (or the '<class>' literal). */
export const markerComment = (findingClass: string): string =>
  `<!-- ${MARKER_PREFIX} ${findingClass}; pruned by /gaia-cleanse on obsolescence/redundancy/supersession/duplication only, never for non-recurrence -->`;
