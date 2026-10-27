---
type: decision
status: active
created: 2026-10-27
updated: 2026-10-27
promoted_at: 2026-10-27T03:07:07Z
promoted_hash: sha256:ef54f268bc7d36a4659d7d81d0e0d1ee687fa96d1870280242f63dbc2b8aff78
pr_number: 3116
tags: [codify, policy-memory, promoted]
---

# Shared Codify Declines

A `/gaia-codify` decline is a team decision, not a private one. Each decline is one small JSON file in the committed `.gaia/codify-declines/` folder, published through the codify run's pull request, so once that pull request merges it suppresses the candidate on every clone whose checked-out tree holds it, and no teammate pays for the same review again. [[Policy-Memory Loop]] describes how the loop uses a decline; this page records why the store has the shape it has.

## Decisions

### One file per decline, not one shared file

The codify nudge fires on every teammate's clone at the same moment, so simultaneous decline pull requests are the expected case. Two branches that each append a line to one shared file conflict when the second squash-merges, and GitHub's server-side merge is not documented to honor a `merge=union` driver. A folder in which each decline is a new file merges cleanly however many teammates decline at once.

- A file is never edited. A run writes a new one, and deletes one only as lapsed-file housekeeping inside a codify pull request it is already opening; no run opens a pull request just to delete lapsed files.
- The file name is the class slug (lowercase ASCII), the UTC date and time, and a random hex suffix. A committer-derived suffix would collide for one engineer declining on two clones in the same second; the random one does not, and the write refuses an existing name rather than replacing it.
- The reader takes the class and the timestamp from the file's content, never its name. The name serves only uniqueness and the tie-break.
- Each file carries a decline-file format version, kept separate from the tally schema version: a file the reader cannot parse, or whose format version it does not know, suppresses nothing, every other file still applies, and the skip is reported as a structured `skipped_decline_file` error that the next `/gaia-codify` run names. A tally-schema mismatch is not a skip; it lifts the decline, as below.

For each class, the file with the latest timestamp governs, compared as parsed instants so fractional-second precision cannot reorder them, with a tie going to the lexicographically last file name. A timestamp later than the reader's clock is read as the current time, so a skewed clock cannot outrank later declines or delay its own lapse.

### A decline lapses by age

A decline lifts on a material rise of its class's live count over the recorded count (the shared `isMaterialRise` rule), on a tally-schema-version change, or once its recorded timestamp is older than one tally window. Age is judged by the timestamp in the file, never by git commit or author time, so a rebase or a late merge does not reset it. A class leaving the window does not lift a decline: a class that drops out and recurs within one window of its decline stays suppressed below a material rise. The cost of the age lapse is that a steadily recurring declined class comes back for review once per window rather than staying suppressed until it rises; because declines are shared, one re-decline covers the whole team.

A lapsed file is inert, so lapsing needs no state and no commit. The `gaia codify-ledger lapsed` verb names lapsed files so a codify pull request can delete them.

### A teammate can still approve

A committed decline drops the class from every clone's candidate list, so the tally reports declined classes in a separate `team_declined` field. Every `/gaia-codify` run shows them in a short section apart from the candidates, and the statusline nudge never counts them. A teammate who disagrees approves the class from that section. A prose-rule approval marks the class promoted once the rule merges, so the rule wins; any other approve form writes its change and leaves the decline to lift on its own terms. No run edits or deletes a live decline, so the approval is also the way to undo a mistaken one.

### The unclassified signal uses the same store

The suppression of the `holistic/unclassified` recurrence signal is recorded in the same folder, keyed on that classless fallback, on the same terms as a decline. It is written only by a run that showed the signal un-suppressed, and only on an explicit human act: accepting the run's presented plan, or, on a run with no candidates, a yes to the question that run asks before writing.

### Publishing through the codify pull request

A run whose only writes are declines, the unclassified suppression, or both isolates before its first write and opens a pull request exactly as an approval run does, with the same check watch and merge question. No Code Audit Team member's glob matches the folder, and GAIA's own audit config lists it among its unowned paths, so a decline-only pull request owes no member and merges through the out-of-scope path with no pre-dispatch verification run.

### The folder belongs to the adopter

The folder sits under the tracked `.gaia/` tree, outside the gitignored `.gaia/local`. It is release-excluded, so it is absent from the manifest and GAIA never ships its own declines, and it is a reference opt-out in the release scrub config. `/update-gaia` treats anything absent from the manifest as the adopter's own data, so an update never overwrites, prunes or flags an adopter's declines. These are the same registrations that protect `/gaia-residue`'s dismissal store, the precedent for a committed store published through its command's own pull request.

### The legacy ledger is read, never written

The earlier per-clone ledger, `.gaia/local/codify/declines.json`, is still read, read-only, under the same age-lapse and material-rise terms, so a decline made before the committed store keeps suppressing on its own clone until it lapses, exactly as long as a committed decline would. Nothing writes it, from a codify run or from the background tally, and nothing copies its entries into the committed store. While both sources are read, a class is suppressed when either suppresses it. An unreadable legacy ledger fails open: it suppresses nothing and is reported as a structured `malformed_decline_ledger` error, because an unparseable file can never age-lapse and failing closed would silence a clone indefinitely.

The review snapshot that silences a clone's nudge after a completed review stays per-clone. A committed single-baseline snapshot would conflict on every review and force a pull request for each one, and once declines and approvals are shared a teammate's later run already lists only deferred and genuinely new candidates. A clone that has declined a class but whose pull request has not merged still lists that class on a manual `/gaia-codify` run, which is honest: an unmerged decline is not yet team policy.
