#!/bin/bash
# A07-AC-6 (part): an origin/main that does not resolve starts no adoption and logs one line; once it resolves (and has no
# graph) the adoption starts. A07-AC-1 (part): a checkout without scheduler/unattended-adopt.md starts no adoption, logs one
# line, and the tick carries on. Assumed: the line names adoption ("adopt" in any case); the checkout's missing template is
# named by its file name.
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"   # the runner runs *.test.sh with sh, except loop.test.sh
. "$(dirname "$0")/testdata/lib/loop-prelude.sh"
. "$src/testdata/lib/loop-a07.sh"

# --- an origin/main that does not resolve: the fake forge's only branch is dev, the fetch works, origin/main is not there
a07_fork a07
git -C "$G04/fk/a07/repo.git" branch -m main dev
git -C "$G04/fk/a07/repo.git" symbolic-ref HEAD refs/heads/dev
a07_run a07
ticks 5
chk "A07-AC-6: origin/main does not resolve: no session starts" test ! -e "$A07/claude.log"
chk "A07-AC-6: the unit starts nothing (no adopt/ state folder with a session)" test -z "$(ls "$st"/adopt/*/session.pid 2>/dev/null)"
chk "A07-AC-6: one status-log line says adoption does not start (origin/main does not resolve), however many ticks" test "$(a07_nlines 'adopt')" = 1
chk "A07-AC-6: that line names origin/main" sh -c "grep -iE 'adopt' '$st/status.log' | grep -qE 'origin/main'"
# main appears, without a graph: the adoption starts
a07_main a07 none
need "A07-AC-6: once origin/main resolves and has no graph, the adopt/scaffold session starts" 15 a07_logged '^scaffold run 1 /noodlebot:adopt '
a07_stop

# --- a checkout without the template (a second repository on the same scheduler copy, whose template is removed)
a07_no_template
a07_skip=0
r0=$(a07_runs scaffold)
a07_fork a07t
a07_run a07t
ticks 5
chk "A07-AC-1: no unattended-adopt.md: no adoption session starts" test "$(a07_runs scaffold)" = "$r0"
chk "A07-AC-1: no unattended-adopt.md: no adopt/scaffold session in the second loop's state" test -z "$(ls "$st"/adopt/*/session.pid 2>/dev/null)"
chk "A07-AC-1: no unattended-adopt.md: one status-log line says so (names the template)" test "$(a07_nlines 'unattended-adopt')" = 1
chk "A07-AC-1: no unattended-adopt.md: that line says no adoption starts" sh -c "grep -iE 'unattended-adopt' '$st/status.log' | grep -qiE 'adopt.*(not started|no adoption|nothing)|(not started|no adoption|nothing).*adopt'"
chk "A07-AC-1: no unattended-adopt.md: the tick carries on (the loop keeps ticking)" ticks 2
a07_stop
loop_end
