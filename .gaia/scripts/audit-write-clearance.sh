#!/usr/bin/env bash
# audit-write-clearance.sh: the ONE shared writer for every Code Audit Team
# clearance artifact, replacing a byte-identical inline `printf` duplicated
# across the agent definitions.
#
# Usage:
#   audit-write-clearance.sh --root <path> --member <name> \
#                            --provenance earned|refused \
#                            [--base <sha>] \
#                            [--scope-digest <64-hex>] \
#                            [--supersede-refusal <reason>] \
#                            [--review full|light] \
#                            [--route-record <path>] \
#                            [--help|-h]
#
#   --root         REQUIRED, and validated: it must be a checkout ROOT, not a
#                  subdirectory of one and not a path a worktree used to
#                  occupy. The member's branch-own digest is derived from it
#                  (never from the caller's CWD) via the digest engine
#                  (.claude/hooks/lib/audit-digest.sh), which bounds a worktree
#                  run from stamping a marker keyed to another worktree's
#                  branch.
#   --member       REQUIRED. The Code Audit Team member writing the clearance.
#   --provenance   REQUIRED. earned | refused.
#   --supersede-refusal <reason>
#                  OPTIONAL, valid ONLY with --provenance earned (a usage error
#                  with refused, or with an empty/whitespace reason). A member's
#                  explicit, reasoned reversal of its OWN prior same-digest
#                  refusal: when set and a sibling <digest>[.<member>].refused
#                  exists, the earned body records a `supersedes` block naming
#                  the reason, and the writer removes that sibling refusal AFTER
#                  the earned .ok is atomically published. This is the only
#                  legitimate refused->earned path on identical content (an
#                  operator acknowledges an unaddressed Major with a stated
#                  reason, so the digest does not move). Absent the flag, an
#                  earned write NEVER touches a sibling refusal, that strict
#                  precedence is the anti-gaming control (a bare re-run must not
#                  clear a refusal; only an authored, reasoned supersede may).
#   --base <sha>   OPTIONAL. The incremental audit base sha. When given, the
#                  write also maintains the re-run CARRY-FORWARD LEDGER
#                  (.gaia/local/audit/<audit-key>.rerun.json, at the derived
#                  key described under "Audit key" in the accounting sibling; this value is the
#                  key's fallback, and its presence is what arms the ledger
#                  write). The open-finding accounting read does not need it.
#                  This is what makes a refusal self-describing. A refusal
#                  blocks a merge, and a refusal is retired only by its own
#                  author, so an operator who cannot learn WHAT was refused can
#                  neither repair it nor legitimately supersede it. The ledger
#                  is that briefing, derived from the member's own findings
#                  sidecar (see "Ledger" in the ledger sibling), so it costs the member nothing
#                  beyond the report it already wrote.
#   --scope-digest <64-hex>
#                  OPTIONAL, gated on a PLAIN earned write only: never
#                  --provenance refused; an earned write carrying
#                  --supersede-refusal is conditionally exempt, see the
#                  staleness gate's header comment (gates sibling) for the
#                  exact condition. A member resolves its review scope at one
#                  HEAD, then finishes and writes at a later one; this
#                  carries the digest captured at scope resolution
#                  (.gaia/scripts/audit-scope-digest.sh --capture) for
#                  comparison against the digest this script derives fresh,
#                  right here, from the CURRENT --root. A difference means the
#                  member's review scope no longer describes what the marker
#                  would attest to, so the write refuses rather than
#                  publishing a marker keyed to unread content. A malformed
#                  value (not exactly 64 lowercase hex) is a usage error, not a
#                  staleness refusal.
#   --review full|light
#                  OPTIONAL, valid ONLY with --provenance earned. Earned bodies
#                  always carry `review`; absent the flag it is `full`, so every
#                  existing call site is unchanged. A refused body carries no
#                  `review` key. `light` is the cheap clearance a fresh router
#                  decision licenses, and it is never an incremental-scope anchor.
#                  It requires --route-record and refuses (exit 2, nothing
#                  written, no sibling touched) unless the record parses, says
#                  route light for this member, and names the digest and HEAD tree
#                  this script derives fresh from --root. It is a usage error
#                  with --supersede-refusal, and it refuses when a same-digest
#                  refusal sibling exists: a light clearance never supersedes or
#                  retires a refusal. It still passes the --scope-digest gate.
#   --route-record <path>
#                  Required with --review light, a usage error otherwise: the
#                  router's decision record.
#
# Behavior (all contract):
#   - Creates <root>/.gaia/local/audit/ if absent, except in a linked worktree
#     whose .gaia/local is not a link: that refuses with exit 2 and names
#     .claude/hooks/provision-worktree.sh as the repair.
#   - Writes ATOMICALLY: a temp file in the target directory, then `mv`.
#   - Every write lands unconditionally: it overwrites a stale body at the
#     same path. There is no create-only guard and no carried family to
#     dominate; provenance is earned or refused only.
#   - On a REFUSAL, also calls .claude/hooks/post-audit-status.sh
#     with the refusal it just wrote, so the required GAIA-Audit status falls to
#     `failure` and the merge paths that never run the local hook (GitHub's
#     auto-merge) cannot complete over a live refusal. Best-effort: its output
#     goes to stderr and any failure is absorbed, so stdout stays the marker
#     path and a refusal that cannot post one is still durably on disk.
#   - Exit 0 on write; stdout is the marker path. Exit 2 on a usage error, when
#     the member's branch-own digest cannot be derived, or when the body cannot be
#     built (message on stderr) -- never a marker written keyed to an empty or
#     partial digest, and never an empty or partial body published. A base tip
#     missing locally and a merge base that is not unique are exit 2 with their
#     one next step named (`git fetch origin`; the merge that makes the merge base
#     unique). Exit 3 when the open-finding accounting (accounting sibling) fails: nothing is
#     published, no ledger byte changes, no status is posted, and the scope
#     capture is kept.
#   - The body is schema 4. `schema` is informational: no reader validates it,
#     and clearance_acceptable ignores it entirely, so a schema-3 body on disk
#     still validates exactly as before. A refused body carries
#     `review_coverage: {scope_digest}` when this member's scope capture at the
#     derived key recorded the write-time digest and was not taken on a
#     caller-overridden review base: the proof that the refusal's review covered
#     the content it is keyed to, which the incremental-scope resolver requires
#     before it anchors a member on its own refusal. Otherwise the key is absent.
#   - jq is REQUIRED: it builds the body, so every value is escaped by
#     construction. Absent jq the writer fails closed rather than emitting a
#     hand-assembled body. The gate's reader requires jq for the same reason.
#
# The phases live in siblings beside this file, each with its own header:
#   audit-write-clearance-args.sh        flag defaults, argument loop, usage errors
#   audit-write-clearance-gates.sh       branch-own digest, light route, staleness gate
#   audit-write-clearance-accounting.sh  audit key, open-finding accounting
#   audit-write-clearance-publish.sh     atomic marker publish, refusal status signal
#   audit-write-clearance-ledger.sh      re-run carry-forward ledger write
# This file loads them and runs the phases in the order below; the order is
# part of the contract (accounting before publish, publish before the ledger,
# the status signal last).
#
# This writer is NOT evidence-gated: it takes no --report, calls no detector,
# and its body carries no evidence block. It raises the forgery bar (a forged
# marker must now be writer-shaped) but does not close the pool's
# write-integrity weakness; that remains its own separate concern.
#
# Bash 3.2 compatible (macOS-default bash). Never cds the main shell (only
# subshells and command substitutions cd).

# shellcheck disable=SC2034,SC2154,SC2329  # the phase globals and usage() cross into the sibling phases

set -uo pipefail

# The default member owns the infix-free filename family.
DEFAULT_MEMBER="code-audit-frontend"

usage() {
  cat <<'EOF' >&2
usage: audit-write-clearance.sh --root <path> --member <name>
                                --provenance earned|refused
                                [--base <sha>]
                                [--scope-digest <64-hex>]
                                [--supersede-refusal <reason>]
                                [--review full|light]
                                [--route-record <path>]
                                [--help|-h]

  --base <sha>                  the incremental audit base sha; arms the re-run
                                carry-forward ledger write so a refusal briefs
                                its own repair. The ledger write is best-effort;
                                the open-finding accounting read gates every
                                write and does not need --base.
  --scope-digest <64-hex>       gated on a plain earned write; refuses when it
                                differs from the write-time digest. See the
                                header comment above.
  --supersede-refusal <reason>  valid only with --provenance earned; records a
                                reasoned reversal of this member's own prior
                                same-digest refusal and removes it.
  --review full|light           valid only with --provenance earned; default
                                full. light also needs --route-record.
  --route-record <path>         the router decision record a light review
                                requires; a usage error otherwise.

exit 0 = written (marker path on stdout); 2 = usage, digest, or build error;
3 = open-finding accounting failure (nothing published).
EOF
}

error() {
  printf 'audit-write-clearance: %s\n' "$1" >&2
}

# Resolve the digest engine and the version normalizer from THIS file's own
# on-disk location, never cwd, never $ROOT: .gaia/scripts -> ../../.claude/hooks/lib.
_write_clearance_library_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.claude/hooks/lib" 2>/dev/null && pwd)" || true
if [ -n "${_write_clearance_library_directory:-}" ] && [ -f "$_write_clearance_library_directory/audit-branch-patch.sh" ]; then
  # shellcheck source=/dev/null
  . "$_write_clearance_library_directory/audit-branch-patch.sh"
fi
if [ -n "${_write_clearance_library_directory:-}" ] && [ -f "$_write_clearance_library_directory/audit-base-provenance.sh" ]; then
  # shellcheck source=/dev/null
  . "$_write_clearance_library_directory/audit-base-provenance.sh"
fi
if [ -n "${_write_clearance_library_directory:-}" ] && [ -f "$_write_clearance_library_directory/audit-digest.sh" ]; then
  # shellcheck source=/dev/null
  . "$_write_clearance_library_directory/audit-digest.sh"
fi
if [ -n "${_write_clearance_library_directory:-}" ] && [ -f "$_write_clearance_library_directory/gaia-version.sh" ]; then
  # shellcheck source=/dev/null
  . "$_write_clearance_library_directory/gaia-version.sh"
fi

# The ledger's key rule, shared with every other worktree-partitioned artifact.
# Sourced defensively, exactly as the digest engine above is: the marker write
# is this script's job and the ledger is a rider, so a missing key lib must
# degrade to "no ledger", never to a failed or noisy clearance write.
_write_clearance_script_directory="$(dirname "${BASH_SOURCE[0]}")"
if [ -f "${_write_clearance_script_directory}/audit-key-lib.sh" ]; then
  # shellcheck source=/dev/null
  . "${_write_clearance_script_directory}/audit-key-lib.sh"
fi
if [ -f "${_write_clearance_script_directory}/main-root-lib.sh" ]; then
  # shellcheck source=/dev/null
  . "${_write_clearance_script_directory}/main-root-lib.sh"
fi

# The shared base resolver whose line 1 the audit key is derived from, located
# the same way: .gaia/scripts -> ../../.github/audit. Absent, the key falls
# back to the --base key.
_write_clearance_resolver_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.github/audit" 2>/dev/null && pwd)" || true
_write_clearance_resolver=""
if [ -n "${_write_clearance_resolver_directory:-}" ] && [ -f "${_write_clearance_resolver_directory}/resolve-audit-base.sh" ]; then
  _write_clearance_resolver="${_write_clearance_resolver_directory}/resolve-audit-base.sh"
fi

# The writer's phases, sourced from this file's own directory, never cwd.
# Unlike the libraries above, none of them degrades: a writer missing a phase
# would publish a marker that phase exists to gate. So a sibling that is absent,
# or that does not define its last function once sourced (bash 3.2 can stop
# part way through a file it cannot parse and carry on), refuses with exit 2
# before anything is written, never exit 127.
_write_clearance_phase_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P)" || _write_clearance_phase_directory=""
for _write_clearance_phase in \
  "args:_write_clearance_validate_arguments" \
  "gates:_write_clearance_check_scope_digest" \
  "accounting:_write_clearance_account_open_findings" \
  "publish:_write_clearance_post_refusal_status" \
  "ledger:_write_clearance_write_ledger"; do
  _write_clearance_phase_file="${_write_clearance_phase_directory}/audit-write-clearance-${_write_clearance_phase%%:*}.sh"
  if [ ! -f "$_write_clearance_phase_file" ]; then
    error "cannot load the writer phase '$_write_clearance_phase_file': it is missing, so nothing is written"
    exit 2
  fi
  # shellcheck source=/dev/null
  . "$_write_clearance_phase_file"
  if ! command -v "${_write_clearance_phase#*:}" >/dev/null 2>&1; then
    error "cannot load the writer phase '$_write_clearance_phase_file': it did not define ${_write_clearance_phase#*:}, so nothing is written"
    exit 2
  fi
done

_write_clearance_parse_arguments "$@"

# --root must BE a checkout root, not a subdirectory of one and not a path a
# worktree used to occupy. The branch-own digest, the HEAD tree and the marker
# store below are all derived from it, so a path that merely SITS INSIDE a
# checkout mints a marker attesting to content the caller never named. Compare
# physically resolved paths, via `cd <path> && pwd -P` rather than `realpath`
# (not guaranteed present on macOS -- see .gaia/scripts/main-root-lib.sh's
# header), so a symlinked checkout path passes a comparison it should pass.
_root_toplevel="$(git -C "$ROOT" rev-parse --show-toplevel 2>/dev/null || true)"
if [ -z "$_root_toplevel" ]; then
  error "--root '$ROOT' is not a git checkout"
  exit 2
fi
_root_physical_path="$(cd "$ROOT" 2>/dev/null && pwd -P)" || _root_physical_path=""
_toplevel_physical_path="$(cd "$_root_toplevel" 2>/dev/null && pwd -P)" || _toplevel_physical_path=""
if [ -z "$_root_physical_path" ] || [ "$_root_physical_path" != "$_toplevel_physical_path" ]; then
  error "--root '$ROOT' is not a checkout root (its checkout root is '$_root_toplevel')"
  exit 2
fi

_write_clearance_validate_arguments
_write_clearance_derive_digest

audit_directory="${ROOT}/.gaia/local/audit"

# Filename family for this member/provenance: keyed to the member's content
# digest, not the tree.
if [ "$MEMBER" = "$DEFAULT_MEMBER" ]; then
  infix=""
else
  infix=".${MEMBER}"
fi
earned_path="${audit_directory}/${digest}${infix}.ok"
refused_path="${audit_directory}/${digest}${infix}.refused"

# Whether a --supersede-refusal write actually has something to supersede.
# The flag alone is not enough: the gate below and do_supersede further down
# both need to agree on this, so it is derived once here rather than each
# re-deriving its own copy that could drift from the other's.
supersede_retires_refusal=0
if [ "$SUPERSEDE_SEEN" -eq 1 ] && [ -f "$refused_path" ]; then
  supersede_retires_refusal=1
fi

_write_clearance_check_light_route
_write_clearance_check_scope_digest

# jq builds the body. Fail closed here rather than at the write, so a missing
# jq never leaves a half-provisioned audit dir behind.
command -v jq >/dev/null 2>&1 || {
  error "jq is required to write a clearance marker"
  exit 2
}

# Resolve the real HEAD tree and commit sha from the root, never from CWD.
# Plain data fields on the body now, not the filename key.
tree="$(git -C "$ROOT" rev-parse "HEAD^{tree}" 2>/dev/null || true)"
if [ -z "$tree" ]; then
  error "cannot resolve HEAD tree for --root '$ROOT'"
  exit 2
fi
sha="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || true)"

# Version is the .gaia/VERSION literal under the root. Advisory data, never a
# merge-gate contract.
version=""
if command -v gaia_read_version >/dev/null 2>&1; then
  version="$(gaia_read_version "${ROOT}/.gaia/VERSION")"
else
  # Degrade exactly as an absent VERSION file does rather than failing the
  # write: the marker's validity key is the digest above, not this field.
  error "version normalizer unavailable (.claude/hooks/lib/gaia-version.sh); recording an empty version"
fi

_write_clearance_derive_audit_key
_write_clearance_account_open_findings

# Every member files a FINDINGS sidecar, its report of record, so this flag
# is always true. No CLI flag for it.
sidecar="true"

audited_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

case "$PROVENANCE" in
  earned)  target="$earned_path" ;;
  refused) target="$refused_path" ;;
esac

# Supersession is an EARNED-only, explicit act. It records the reversal in the
# body and removes the sibling refusal only when the flag was passed AND a
# same-digest refusal is actually on disk. Absent the flag, do_supersede stays
# false and the sibling refusal is never touched: an earned write can only clear
# a refusal that its author explicitly, reasonedly reverses, never a bare re-run
# (the anti-gaming invariant). See the staleness gate's header comment in
# audit-write-clearance-gates.sh for what happens with the flag but no sibling
# refusal on disk.
do_supersede=false
if [ "$PROVENANCE" = "earned" ] && [ "$supersede_retires_refusal" -eq 1 ]; then
  do_supersede=true
fi

mkdir -p "$audit_directory" || {
  error "cannot create audit directory '$audit_directory'"
  exit 2
}

_write_clearance_publish_marker
_write_clearance_write_ledger
_write_clearance_post_refusal_status

printf '%s\n' "$target"
exit 0
