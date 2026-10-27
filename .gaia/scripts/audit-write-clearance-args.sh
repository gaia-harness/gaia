#!/usr/bin/env bash
# audit-write-clearance-args.sh: the clearance writer's flag defaults, its
# argument loop, and its usage-error validations, as two functions the parent
# calls on either side of its own --root checkout-root check.
# audit-write-clearance.sh sources it from its own directory; it is never run
# on its own. Nothing here is `local`: every variable it sets is read by the
# writer's later phases.
#
# Bash 3.2 compatible (macOS-default bash).

# shellcheck disable=SC2034  # the flag globals are read by the parent and the other siblings

# _write_clearance_parse_arguments "$@": sets the flag globals and requires
# --root. A usage error exits 2 and --help exits 0, from inside the function,
# so the writer is never run past a bad command line. The parent validates that
# --root is a checkout root between this and _write_clearance_validate_arguments.
_write_clearance_parse_arguments() {
  ROOT=""
  MEMBER=""
  PROVENANCE=""
  BASE=""
  # SUPERSEDE_SEEN records that the flag was passed at all, kept separate from
  # SUPERSEDE_REASON so that an empty reason (flag present, value blank) is a
  # usage error while an absent flag is the ordinary no-supersede path.
  SUPERSEDE_SEEN=0
  SUPERSEDE_REASON=""
  # SCOPE_DIGEST_SEEN mirrors SUPERSEDE_SEEN above: a member that passes an
  # empty value must hit the format-validation usage error, not read as "flag
  # absent" and slip past the staleness gate silently.
  SCOPE_DIGEST_SEEN=0
  SCOPE_DIGEST=""
  # REVIEW_SEEN mirrors SUPERSEDE_SEEN: an empty value must fail validation
  # rather than read as an absent flag.
  REVIEW_SEEN=0
  REVIEW="full"
  ROUTE_RECORD_SEEN=0
  ROUTE_RECORD=""

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --root)
        ROOT="${2:-}"
        shift 2 2>/dev/null || shift
        ;;
      --member)
        MEMBER="${2:-}"
        shift 2 2>/dev/null || shift
        ;;
      --provenance)
        PROVENANCE="${2:-}"
        shift 2 2>/dev/null || shift
        ;;
      --base)
        BASE="${2:-}"
        shift 2 2>/dev/null || shift
        ;;
      --scope-digest)
        SCOPE_DIGEST_SEEN=1
        SCOPE_DIGEST="${2:-}"
        shift 2 2>/dev/null || shift
        ;;
      --supersede-refusal)
        SUPERSEDE_SEEN=1
        SUPERSEDE_REASON="${2:-}"
        shift 2 2>/dev/null || shift
        ;;
      --review)
        REVIEW_SEEN=1
        REVIEW="${2:-}"
        shift 2 2>/dev/null || shift
        ;;
      --route-record)
        ROUTE_RECORD_SEEN=1
        ROUTE_RECORD="${2:-}"
        shift 2 2>/dev/null || shift
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      *)
        error "unrecognized argument: $1"
        usage
        exit 2
        ;;
    esac
  done

  if [ -z "$ROOT" ]; then
    error "--root is required"
    usage
    exit 2
  fi
}

# _write_clearance_validate_arguments: every usage-error validation after the
# --root checkout-root check, each exiting 2.
_write_clearance_validate_arguments() {
  # A provisioned linked worktree's .gaia/local is a link into the main checkout,
  # where the merge gate and the round evaluator read the audit store. In an
  # unprovisioned one the writer's mkdir would create a real directory, and the
  # marker landing there is one nothing reads: the round reads `unknown` and the
  # gate declines with the marker absent. Refuse before writing, naming the
  # repair. The main checkout is never a linked worktree, so it never takes this.
  if command -v gaia_is_linked_worktree >/dev/null 2>&1 \
    && gaia_is_linked_worktree "$ROOT" && [ ! -L "$ROOT/.gaia/local" ]; then
    error "--root '$ROOT' is a linked worktree whose .gaia/local is not linked to the main checkout, so a marker written here would never reach the merge gate. Run: bash .claude/hooks/provision-worktree.sh '$ROOT' (idempotent; it also moves any audit artifacts already stranded in the tree), then re-dispatch the member."
    exit 2
  fi

  if [ -z "$MEMBER" ]; then
    error "--member is required"
    usage
    exit 2
  fi
  case "$PROVENANCE" in
    earned|refused) ;;
    "")
      error "--provenance is required"
      usage
      exit 2
      ;;
    *)
      error "invalid --provenance '$PROVENANCE' (want earned|refused)"
      usage
      exit 2
      ;;
  esac

  if [ "$REVIEW_SEEN" -eq 1 ]; then
    case "$REVIEW" in
      full|light) ;;
      *)
        error "invalid --review '$REVIEW' (want full|light)"
        usage
        exit 2
        ;;
    esac
    if [ "$PROVENANCE" != "earned" ]; then
      error "--review is valid only with --provenance earned"
      usage
      exit 2
    fi
  fi
  if [ "$REVIEW" = "light" ]; then
    if [ "$ROUTE_RECORD_SEEN" -ne 1 ] || [ -z "$ROUTE_RECORD" ]; then
      error "--review light requires --route-record"
      usage
      exit 2
    fi
    if [ "$SUPERSEDE_SEEN" -eq 1 ]; then
      error "--review light cannot be combined with --supersede-refusal"
      usage
      exit 2
    fi
  elif [ "$ROUTE_RECORD_SEEN" -eq 1 ]; then
    error "--route-record is valid only with --review light"
    usage
    exit 2
  fi

  # --supersede-refusal is a reasoned reversal of an EARNED write only. Reject it
  # on a refusal (a refusal supersedes nothing) and reject an empty/whitespace
  # reason (supersession must be auditable, so it must carry a stated reason).
  if [ "$SUPERSEDE_SEEN" -eq 1 ]; then
    if [ "$PROVENANCE" != "earned" ]; then
      error "--supersede-refusal is valid only with --provenance earned"
      usage
      exit 2
    fi
    _supersede_trimmed="${SUPERSEDE_REASON#"${SUPERSEDE_REASON%%[![:space:]]*}"}"
    _supersede_trimmed="${_supersede_trimmed%"${_supersede_trimmed##*[![:space:]]}"}"
    if [ -z "$_supersede_trimmed" ]; then
      error "--supersede-refusal requires a non-empty reason"
      usage
      exit 2
    fi
  fi

  # --scope-digest, when present, must be exactly 64 lowercase hex: the shape
  # the digest engine emits. This is a usage error, not a staleness refusal, so
  # a caller passing a malformed value gets a distinct diagnostic from a caller
  # whose digest genuinely rotated. Bash-3.2-safe `case`, not `[[ =~ ]]`.
  _scope_digest_malformed=0
  if [ "$SCOPE_DIGEST_SEEN" -eq 1 ]; then
    case "$SCOPE_DIGEST" in
      *[!0-9a-f]* | '') _scope_digest_malformed=1 ;;
    esac
    if [ "${#SCOPE_DIGEST}" -ne 64 ]; then
      _scope_digest_malformed=1
    fi
  fi
  if [ "$_scope_digest_malformed" -eq 1 ]; then
    error "--scope-digest must be a 64-hex digest"
    usage
    exit 2
  fi
}
