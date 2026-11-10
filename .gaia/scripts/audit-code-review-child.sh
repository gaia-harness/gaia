# shellcheck shell=bash
# What the review child is allowed to do and what bounds it: its generated settings,
# its argv, the deadline supervisor, the group check and the tree snapshot. Sourced
# by audit-code-review.sh, never executed; does no work at source time. Every input
# is an argument, so nothing here reads the caller's globals. Bash 3.2 compatible.
# Never `cd`s.
#
# WHY SUBTRACTION. --allowedTools only adds grants, and the project's allow list
# adds to it: with --allowedTools Read,Grep,Glob under dontAsk, a child edited a
# file through the project's own Edit row. So the design is what the effective set
# cannot contain, and no part of it depends on the model's cooperation: --tools
# leaves mutating tools nothing to be granted to, --restricted drops the user, project
# and local settings files' allow rows and hooks, --strict-mcp-config loads no servers, and under
# dontAsk the generated settings' literal git rows are all Bash can do. Never fall
# back to an allow list.
#
# HONEST LIMITS. --restricted leaves managed settings in force, so an organization's
# managed allow row could still add a grant; the tree check after each attempt is
# the backstop there. That check sees branch, HEAD, tree and porcelain status, so it
# does not see a git-ignored path, or a further edit to a file already dirty before
# the spawn. It catches a move after the fact and restores nothing, which is why it
# stops for a human. The child's restricted launch also ignores user settings, so a
# provider or auth set in user `env` or `apiKeyHelper` does not reach it.
# shellcheck disable=SC2016

# Rows are literal prefixes with the root typed in, so `git -C <root> diff` cannot
# also match `git -C <root> commit -m diff`. Deny beats allow: these read-only verbs
# can write or run through the denied forms, and can read a file outside the tree
# (`git diff /dev/null .env` turns on --no-index unspelled, `git blame --contents`),
# which the deny rows catch only in their literal spellings. The guard hook's token
# deny-list denies the further forms named in the comment over its Bash check. git grep
# is left out entirely because
# -O runs a pager, and the child has the Grep tool. A bare Read admits the template's
# own file names, including a `$` route. No Read() deny row: the sensitive-read
# hook's header records why one is unaffordable; the guard hook carries that job.
print_child_settings() {
  local root="$1" attempt_directory="$2" guard_script="$3"
  jq -n --arg root "$root" --arg guard "$guard_script" --arg log "$attempt_directory/guard-denials.jsonl" '
    ["diff", "log", "show", "status", "rev-parse", "merge-base", "blame", "ls-files", "cat-file"] as $verbs
    | {permissions: {
         allow: (["Read", "Grep", "Glob"]
           + ([$verbs[] | "Bash(git \(.):*)", "Bash(git -C \($root) \(.):*)"])
           + ["Bash(git branch --show-current)", "Bash(git -C \($root) branch --show-current)"]),
         deny: ["Bash(git * --output*)", "Bash(git * --no-index*)", "Bash(git * --ext-diff*)", "Bash(git * --contents*)", "Bash(git * /dev/null*)", "Bash(git -c *)"]},
       hooks: {PreToolUse: [{matcher: "Read|Grep|Bash", hooks: [{type: "command",
         command: "bash \($guard | @sh) \($log | @sh) \($root | @sh)"}]}]}}'
}

# set_child_argv <target> <settings-file>: one array, never through eval or a shell
# string, since the target and paths are data. --model is the doctrine's review row.
# No effort flag: the level is review depth, and the session's effort stays unpinned.
# No --max-budget-usd: the forked review takes it as a soft budget and returns a partial
# review as success. The deadline is the spend bound; --tools also withholds Agent from the session.
set_child_argv() {
  # The commas are one --tools value, not array separators; the caller reads CHILD_ARGV.
  # shellcheck disable=SC2034,SC2054
  CHILD_ARGV=(claude -p "/code-review high --max-findings all $1" --model opus --output-format json
    --permission-mode dontAsk --restricted --strict-mcp-config --tools Read,Grep,Glob,Bash --settings "$2")
}

# Stock macOS has no timeout or setsid, and a shell job-control group would die
# with the script, so a dead script or unit could leave a child spending. This
# supervisor holds the deadline itself, in a process nothing waits on but the
# script. It ignores TERM, INT and HUP so only its own deadline ends the child.
#
# It leaves the group just before signalling, because a KILL sent to a group the
# sender is in kills the sender, and exit 124 would become 137. Rejoining the outer
# group works whenever the script is alive, since the script is in it; when it
# fails the script is dead and nobody reads the status. The group also gets TERM
# and KILL after a normal child exit, so a grandchild left running stops spending.
# A descendant that calls setsid itself leaves the group and is beyond this.
SUPERVISOR_PROGRAM='
use strict; use warnings; use POSIX qw(:sys_wait_h);
my ($timeout, $grace, $directory, @command) = @ARGV;
my $outer_group = getpgrp();
setpgrp(0, 0) or exit 126;
my $group = $$;
my $child = fork();
exit 126 unless defined $child;
if ($child == 0) {
  chdir $directory or exit 126;
  exec { $command[0] } @command;
  exit 127;
}
$SIG{$_} = "IGNORE" for qw(TERM INT HUP);
my $deadline = time + $timeout;
my ($status, $timed_out);
sub reap { if (!defined $status && waitpid($child, WNOHANG) == $child) { $status = $?; } }
until (defined $status) {
  reap();
  last if defined $status;
  if (time >= $deadline) { $timed_out = 1; last; }
  select(undef, undef, undef, 0.2);
}
setpgrp(0, $outer_group);
kill "TERM", -$group;
my $grace_end = time + $grace;
while (kill(0, -$group) && time < $grace_end) { reap(); select(undef, undef, undef, 0.1); }
kill "KILL", -$group;
waitpid($child, 0) unless defined $status;
exit 124 if $timed_out;
$status = $? unless defined $status;
exit(($status & 127) ? 128 + ($status & 127) : $status >> 8);
'

# start_supervised <timeout> <grace> <directory> <stdout-file> <stderr-file> <command...>:
# backgrounds the supervisor in the caller's shell, so the caller reads $! and waits.
start_supervised() {
  local timeout="$1" grace="$2" directory="$3" stdout_file="$4" stderr_file="$5"
  shift 5
  perl -e "$SUPERVISOR_PROGRAM" "$timeout" "$grace" "$directory" "$@" >"$stdout_file" 2>"$stderr_file" </dev/null &
}

# The tree check's snapshot. --untracked-files=all so a new file inside an already
# untracked directory shows, and so status.showUntrackedFiles cannot blind it.
tree_snapshot() {
  local root="$1"
  git -C "$root" branch --show-current
  git -C "$root" rev-parse HEAD 'HEAD^{tree}'
  git -C "$root" status --porcelain --untracked-files=all
}

# Confirms the group is gone, which is what lets a retry or a record write happen.
# The supervisor normally guarantees it; this covers a supervisor killed from
# outside, whose group could outlive it.
wait_group_gone() {
  local pgid="$1" tick=0
  while kill -0 -- "-$pgid" 2>/dev/null; do
    if [ "$tick" -eq 20 ]; then kill -KILL -- "-$pgid" 2>/dev/null || true; fi
    [ "$tick" -lt 40 ] || return 1
    sleep 0.5
    tick=$((tick + 1))
  done
}
