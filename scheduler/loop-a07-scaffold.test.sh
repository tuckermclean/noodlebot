#!/bin/bash
# A07-AC-1 (loop part): a repository whose main has no graph gets one adopt/scaffold session in its own worktree
# (worktrees/<name>/adopt-scaffold, branch spec/adopt) whose prompt names the repository, the skill (/noodlebot:adopt) and
# its worktree as the checkout; no second start while its spec PR is open; the worktree is removed once the unit wrote
# WAITING-PR. Assumed (the spec leaves them open): the unit's state is state/<name>/adopt/scaffold/, its prompt unattended.md.
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"   # the runner runs *.test.sh with sh, except loop.test.sh
. "$(dirname "$0")/testdata/lib/loop-prelude.sh"
. "$src/testdata/lib/loop-a07.sh"

a07_fork a07
touch "$A07/hold.scaffold"
a07_run a07
need "A07-AC-1: no graph on origin/main: an adopt/scaffold session starts (/noodlebot:adopt <repo>)" 15 a07_logged '^scaffold run 1 /noodlebot:adopt '
wt=$(a07_wt scaffold)
chk "A07-AC-1: the session works in worktrees/<name>/adopt-scaffold, on spec/adopt" a07_logged "^scaffold run 1 .* [|] $wt [|] spec/adopt\$"
u=$(a07_ud scaffold)/unattended.md
repo_named() { grep -qF "$G04/fk/a07" "$u" || grep -qF "acme/a07" "$u"; }
chk "A07-AC-1: its prompt (adopt/scaffold/unattended.md) names the repository" repo_named
chk "A07-AC-1: its prompt names the skill /noodlebot:adopt" grep -qF '/noodlebot:adopt' "$u"
chk "A07-AC-1: its prompt names its worktree as the checkout to work in" grep -qF "$wt" "$u"
chk "A07-AC-1: the unit has a running session (session.pid)" test -s "$(a07_ud scaffold)/session.pid"
ticks 3
chk "A07-AC-1: one session only while it runs" a07_runis scaffold 1
rm -f "$A07/hold.scaffold"
need "A07-AC-1: the session ends with WAITING-PR (its PR) and its worktree is removed" 20 a07_waiting scaffold
ticks 4
chk "A07-AC-1: no second start while its spec PR is open" a07_runis scaffold 1
chk "A07-AC-1: no other session ran" test "$(grep -c . "$A07/claude.log" 2>/dev/null)" = 1
a07_stop
loop_end
