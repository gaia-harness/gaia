#!/usr/bin/env bats
# The Code Audit Team's dirty-tree posture, held across every member.
#
# A member's clearance marker attests to a per-member content digest computed
# over tracked files AT HEAD (`git ls-tree HEAD`,
# .claude/hooks/lib/audit-digest.sh), while the member reviews a file by
# `Read`ing it, which returns WORKING-TREE bytes. On a dirty tree those two
# disagree, so a pass that reviews the working copy can write a marker
# certifying content nobody read. The posture that closes it is a refusal: the
# scope resolver every member runs (.gaia/scripts/audit-resolve-scope.sh)
# checks `git status --porcelain` over that member's OWN review list right after
# resolving it and prints one `DIRTY=` line per dirty entry, and a gating member
# refuses the pass on any such line.
#
# Scoping the check to the review list rather than the whole tree is
# load-bearing in both directions. It is wide enough, because that list is
# exactly the set the member reads and certifies. And it is narrow enough that a
# dirty file in a different remit, left by the operator or a sibling's work under
# concurrent dispatch, cannot refuse this member's pass.
#
# The suite holds the posture in two halves. The check itself is code, so it is
# driven BEHAVIOURALLY: each member's own resolver invocation, lifted out of its
# definition, runs against a fixture with a dirty in-scope file, a clean tree, a
# dirty out-of-scope file, and a git whose `status` fails. The refusal contract
# is agent-executed instruction prose, so it is held STRUCTURALLY, in the shape
# of audit-guard-structural.bats: the contract lives once, in the "Scope
# resolution" section of the shared member protocol, and every member sends
# itself to that section before it invokes the resolver whose output the
# contract consumes.
#
# Assertion style: bash-3.2-safe per .claude/rules/bats-assertions.md.

# bats file_tags=whole-tree

bats_require_minimum_version 1.5.0

setup() {
  THIS_DIRECTORY="$( cd "$( dirname "$BATS_TEST_FILENAME" )" && pwd )"
  REPO_ROOT="$( cd "$THIS_DIRECTORY/../../.." && pwd )"
  SCRIPT="$REPO_ROOT/.gaia/scripts/audit-resolve-scope.sh"
  PROTOCOL="$REPO_ROOT/.claude/hooks/lib/audit-member-protocol.md"
  . "$REPO_ROOT/.gaia/tests/helpers/catchup-fixture.sh"

  # The Code Audit Team members. The list is spelled out rather than
  # globbed: a glob would silently pass if a member file were renamed away,
  # which is the fail-open this suite exists to prevent. The entries are the
  # authority on how many; deliberately no ROSTER count here or in any comment
  # or test name below, because such a count rots the next time a member joins
  # or leaves and the rotted number reads as an assertion nobody has checked.
  MEMBERS="code-audit-frontend
code-audit-github-workflows
code-audit-maintainer-node
code-audit-maintainer-shell"

  # The members whose clearance actually gates a merge. Currently every
  # roster member, so GATING equals MEMBERS; kept as a separate name because
  # the split (and the withhold contract it names) is a roster property, not
  # an accident of how many members exist today.
  GATING="$MEMBERS"

  # The sentinel the remit filter must never discard, and the artifact rule that
  # keeps a withheld pass from stranding a digest-keyed refusal across a revert.
  SENTINEL_CARVEOUT='is a sentinel rather than a path and withholds unconditionally'
  NO_REFUSAL_ARTIFACT='**Withhold without writing a `.refused` artifact.**'

  # The pointer every member carries to the protocol section holding the
  # refusal contract below. The contract binds a member only through it.
  SCOPE_POINTER='Read `<root>/.claude/hooks/lib/audit-member-protocol.md` by path and follow its "Scope resolution" section'

  # The byte-identical refusal contract.
  REFUSAL='**Any `DIRTY=` line WITHHOLDS this pass.**'

  # The obligation the refusal owes, pinned separately from the sentence that
  # opens it. A refusal that briefs nothing blocks a merge no one can clear, so
  # the sidecar write is the load-bearing half.
  SIDECAR_CLAUSE='write the findings sidecar naming each dirty path'

  # The run-order anchor, so the refusal is reachable from the member's own
  # order of operations rather than stated only beside the resolver command. The
  # specialists carry it in Methodology step 1; the default member's scope run
  # order lives under "Rules-Based Audit" -> "How to run". The two phrase the
  # condition differently, so the pin is the verb both share.
  METHOD_ANCHOR='refuse the pass on any `DIRTY=` line'
}

member_path() {
  printf '%s/.claude/agents/%s.md' "$REPO_ROOT" "$1"
}

# scope_section_file: writes the protocol's "## Scope resolution" section body
# to a file and prints its path, so the contract pins read the section a
# member is sent to rather than anywhere in the protocol.
scope_section_file() {
  local section_path="$BATS_TEST_TMPDIR/scope-section.md"
  awk '/^## Scope resolution$/ { inside = 1; next } inside && /^## / { exit } inside { print }' "$PROTOCOL" > "$section_path"
  [ -s "$section_path" ] || { echo "no \"## Scope resolution\" section in $PROTOCOL" >&2; return 1; }
  printf '%s' "$section_path"
}

# assert_contract_reaches GATING_MEMBERS NEEDLE: NEEDLE sits in the protocol's
# scope section, and every listed member sends itself to that section.
assert_contract_reaches() {
  local members="$1" needle="$2" section member_name
  section="$(scope_section_file)" || return 1
  assert_carries "$section" "$needle" || { echo "the protocol's Scope resolution section lacks: $needle" >&2; return 1; }
  for member_name in $members; do
    assert_carries "$(member_path "$member_name")" "$SCOPE_POINTER" || {
      echo "$member_name does not send its member to the protocol's Scope resolution section" >&2
      return 1
    }
  done
}

# resolver_invocation FILE: the scope-resolver command inside FILE's bash
# fences, one per line. Fence-scoped so a prose mention of the script cannot
# stand in for the command the member actually runs.
resolver_invocation() {
  awk '/^```bash$/ { in_bash_fence = 1; next } /^```$/ { in_bash_fence = 0 } in_bash_fence && /^<root>\/\.gaia\/scripts\/audit-resolve-scope\.sh --member / { print }' "$1"
}

# --- Behavioural fixture -----------------------------------------------------

# make_repo NAME [SCRIPT_SRC]: a committed repo carrying the resolver and
# everything it reaches for, on a feature branch that changed app/a.ts, with
# other/untouched.md committed on the base.
make_repo() {
  local name="$1" script_source_path="$SCRIPT"
  local repository_directory="$BATS_TEST_TMPDIR/$name"
  mkdir -p "$repository_directory/.gaia/scripts" "$repository_directory/.gaia/local/audit" \
    "$repository_directory/.github/audit" "$repository_directory/.claude/hooks/lib" "$repository_directory/other" "$repository_directory/app"
  cp "$script_source_path" "$repository_directory/.gaia/scripts/audit-resolve-scope.sh"
  cp "$REPO_ROOT/.gaia/scripts/audit-scope-digest.sh" \
    "$REPO_ROOT/.gaia/scripts/audit-key-lib.sh" \
    "$REPO_ROOT/.gaia/scripts/audit-member-digest.sh" \
    "$repository_directory/.gaia/scripts/"
  chmod +x "$repository_directory/.gaia/scripts/audit-resolve-scope.sh" "$repository_directory/.gaia/scripts/audit-scope-digest.sh"
  cp "$REPO_ROOT"/.github/audit/resolve-audit-base*.sh "$repository_directory/.github/audit/"
  chmod +x "$repository_directory/.github/audit/resolve-audit-base.sh"
  cp "$REPO_ROOT/.gaia/audit-ci.yml" "$repository_directory/.gaia/"
  cp "$REPO_ROOT/.claude/hooks/lib/audit-scope.sh" \
    "$REPO_ROOT/.claude/hooks/lib/audit-base-provenance.sh" \
    "$REPO_ROOT/.claude/hooks/lib/audit-branch-patch.sh" \
    "$REPO_ROOT/.claude/hooks/lib/audit-rules-changed.sh" \
    "$REPO_ROOT/.claude/hooks/lib/audit-clearance.sh" \
    "$REPO_ROOT/.claude/hooks/lib/audit-digest.sh" \
    "$REPO_ROOT/.claude/hooks/lib/audit-machinery.sh" \
    "$REPO_ROOT/.claude/hooks/lib/gaia-version.sh" \
    "$repository_directory/.claude/hooks/lib/"
  printf '2.0.0\n' > "$repository_directory/.gaia/VERSION"
  printf 'base\n' > "$repository_directory/other/untouched.md"
  git -C "$repository_directory" init -q --initial-branch=main
  git -C "$repository_directory" config user.email t@example.com
  git -C "$repository_directory" config user.name T
  git -C "$repository_directory" config commit.gpgsign false
  git -C "$repository_directory" add -A
  git -C "$repository_directory" commit -q -m init
  # The branch-own patch is measured against refs/remotes/origin/main, with
  # main cached as the feature branch's audit base so no `gh` lookup runs.
  catchup_add_origin "$repository_directory" >/dev/null
  git -C "$repository_directory" checkout -q -b feat
  git -C "$repository_directory" config branch.feat.gaia-audit-base main
  printf 'change\n' > "$repository_directory/app/a.ts"
  git -C "$repository_directory" add -A
  git -C "$repository_directory" commit -q -m "touch app/a.ts"
  printf '%s' "$(cd "$repository_directory" && pwd -P)"
}

# run_member_resolver MEMBER REPO: runs MEMBER's own resolver invocation, as its
# definition spells it, with <root> substituted by REPO and <expected-tree> by
# REPO's HEAD tree. Output lands in bats'
# $output / $stderr / $status.
run_member_resolver() {
  local member="$1" repo="$2" resolver_command
  resolver_command="$(resolver_invocation "$(member_path "$member")")"
  [ -n "$resolver_command" ] || { echo "no resolver invocation in $member" >&2; return 1; }
  resolver_command="${resolver_command//<root>/$repo}"
  resolver_command="${resolver_command//<expected-tree>/$(git -C "$repo" rev-parse 'HEAD^{tree}')}"
  run --separate-stderr bash -c "$resolver_command"
}

# failing_status_shim DIR: a git that fails only `status`, so every other call
# the resolver makes runs for real and a sentinel can only come from the check.
failing_status_shim() {
  local shim="$1"
  mkdir -p "$shim"
  cat > "$shim/git" <<EOF
#!/usr/bin/env bash
for argument in "\$@"; do [ "\$argument" = status ] && exit 128; done
exec $(command -v git) "\$@"
EOF
  chmod +x "$shim/git"
}

assert_carries() {
  grep -qF -- "$2" "$1"
}

# --- Structural pins ----------------------------------------------------------

@test "the dirty-tree refusal contract binds every member (resolver run once under its own name, pointer read before the invocation, sidecar obligation) and every gating member (withhold sentence, run-order anchor, sentinel carve-out, no refusal artifact)" {
  local member_name member_file resolver_command invocation_count invocation_line pointer_line

  # every member runs the scope resolver, exactly once, under its own member name
  for member_name in $MEMBERS; do
    resolver_command="$(resolver_invocation "$(member_path "$member_name")")"
    invocation_count="$(printf '%s' "$resolver_command" | grep -c 'audit-resolve-scope' || true)"
    [ "$invocation_count" -eq 1 ] || { echo "$member_name: expected one resolver invocation in a bash fence, found $invocation_count" >&2; return 1; }
    grep -qF -- "--member $member_name --root <root>" <<<"$resolver_command" || {
      echo "$member_name: resolver invocation does not name its own member and root: $resolver_command" >&2
      return 1
    }
  done

  # every member reads the dirty contract's section before it runs the resolver
  for member_name in $MEMBERS; do
    member_file="$(member_path "$member_name")"
    invocation_line="$(grep -nF -- "<root>/.gaia/scripts/audit-resolve-scope.sh --member $member_name" "$member_file" | head -1 | cut -d: -f1)"
    pointer_line="$(grep -nF -- "$SCOPE_POINTER" "$member_file" | head -1 | cut -d: -f1)"
    [ -n "$invocation_line" ] || { echo "no resolver invocation found: $member_name" >&2; return 1; }
    [ -n "$pointer_line" ] || { echo "no pointer to the protocol's Scope resolution section: $member_name" >&2; return 1; }
    [ "$pointer_line" -lt "$invocation_line" ] || {
      echo "the resolver runs before its member is sent to the contract that reads its output: $member_name" >&2
      return 1
    }
  done

  # every GATING member reaches the byte-identical withhold contract
  assert_contract_reaches "$GATING" "$REFUSAL" || {
    echo "missing or drifted refusal contract" >&2
    return 1
  }

  # every GATING member names the refusal in its run order
  for member_name in $GATING; do
    assert_carries "$(member_path "$member_name")" "$METHOD_ANCHOR" || {
      echo "run order does not name the refusal: $member_name" >&2
      return 1
    }
  done

  # every GATING member exempts the failure sentinel from the remit filter
  assert_contract_reaches "$GATING" "$SENTINEL_CARVEOUT" || {
    echo "fail-closed sentinel is filterable away" >&2
    return 1
  }

  # every GATING member withholds without stranding a refusal artifact
  assert_contract_reaches "$GATING" "$NO_REFUSAL_ARTIFACT" || {
    echo "does not forbid the digest-keyed refusal artifact" >&2
    return 1
  }

  # every member owes the sidecar on the dirty path
  assert_contract_reaches "$MEMBERS" "$SIDECAR_CLAUSE" || {
    echo "refusal does not oblige the findings sidecar" >&2
    return 1
  }
}

# --- Behavioural: each member's own invocation --------------------------------

@test "every member's resolver reports its review scope's dirt: a dirty in-scope file is a DIRTY line and reaches stderr, a clean tree and a dirty file outside the review list report none, a status that cannot run fails closed to the sentinel" {
  local member_name repo shim="$BATS_TEST_TMPDIR/shim"
  repo="$(make_repo dirt)"
  failing_status_shim "$shim"

  # dirty in scope
  printf 'edit\n' >> "$repo/app/a.ts"
  for member_name in $MEMBERS; do
    run_member_resolver "$member_name" "$repo" || return 1
    [ "$status" -eq 0 ] || { echo "$member_name: resolver exited $status: $stderr" >&2; return 1; }
    grep -qxF 'DIRTY= M app/a.ts' <<<"$output" || { echo "$member_name: no DIRTY line for a dirty in-scope file" >&2; return 1; }
    grep -qF 'DIRTY IN REVIEW SCOPE:' <<<"$stderr" || { echo "$member_name: dirty set never reached stderr" >&2; return 1; }
  done

  # clean review list
  git -C "$repo" checkout -q -- app/a.ts
  for member_name in $MEMBERS; do
    run_member_resolver "$member_name" "$repo" || return 1
    [ "$status" -eq 0 ] || { echo "$member_name: resolver exited $status: $stderr" >&2; return 1; }
    grep -q '^DIRTY=' <<<"$output" && { echo "$member_name: DIRTY line on a clean tree" >&2; return 1; }
    true
  done

  # dirty outside the review list
  printf 'edit\n' >> "$repo/other/untouched.md"
  for member_name in $MEMBERS; do
    run_member_resolver "$member_name" "$repo" || return 1
    [ "$status" -eq 0 ] || { echo "$member_name: resolver exited $status: $stderr" >&2; return 1; }
    grep -q '^DIRTY=' <<<"$output" && { echo "$member_name: a sibling's dirt outside the review list reached DIRTY" >&2; return 1; }
    true
  done
  git -C "$repo" checkout -q -- other/untouched.md

  # status cannot run
  for member_name in $MEMBERS; do
    PATH="$shim:$PATH" run_member_resolver "$member_name" "$repo" || return 1
    [ "$status" -eq 0 ] || { echo "$member_name: resolver exited $status: $stderr" >&2; return 1; }
    grep -qxF 'DIRTY=dirty-scope check failed' <<<"$output" || {
      echo "$member_name: a status that could not run read as a clean tree" >&2
      return 1
    }
  done
}
