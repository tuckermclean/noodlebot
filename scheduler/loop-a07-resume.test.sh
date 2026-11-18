#!/bin/bash
# A07 review: (1) A07-AC-2 / Change 2 "a session that ends otherwise (a usage limit, a stop) keeps it for its resume", and the
# S06 limit resume of every other session kind: an adoption session left alive but idle by the usage limit (its log ends with
# the rejection, the reset more than 2 minutes past, the throttle open) is stopped and resumed (claude --resume <session id>,
# the limit-resume prompt), so it does not hold the slot. (3) Change 6: a graph with `adoption` that cannot be parsed keeps
# the triage waiting (issues.py not asked), starts no adoption session and logs the problem once.
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"   # the runner runs *.test.sh with sh, except loop.test.sh
. "$(dirname "$0")/testdata/lib/loop-prelude.sh"
. "$src/testdata/lib/loop-a07.sh"
. "$src/testdata/lib/loop-a07-resume.sh"
resumed() { [ -s "$A07/resume.log" ]; }
a07_fork a07
a07_main a07 two
a07r_claude
a07_run a07
need "A07-AC-2: area one's session starts" 15 a07_logged '^one run 1 '
need "A07-AC-2: its log ends with the usage-limit rejection" 10 a07r_wait_idle one
need "A07-AC-2: the idle adoption session is resumed (claude --resume sid-one)" 12 resumed
chk "A07-AC-2: resumed by the session id of its log" grep -q '^one resume sid-one ' "$A07/resume.log"
chk "A07-AC-2: the resume prompt is the limit-resume prompt (names the usage limit)" grep -qi 'usage limit' "$A07/resume.log"
need "A07-AC-2: the resumed session ends with WAITING-PR (the slot is free again)" 20 a07_waiting one
chk "A07-AC-2: resumed once" test "$(wc -l <"$A07/resume.log")" = 1
chk "A07-AC-2: no new start (the first run only)" a07_runis one 1
a07_stop
# (3) a graph with `adoption` that cannot be parsed
a07_skip=0
rm -f "$A07/issues.called" "$A07/claude.log" "$A07"/runs.*
a07_fork bad
a07r_graph_bad bad
a07_issue bad 5
a07_run bad
bl() { a07_msgs | grep -iE 'graph|adopt' | grep -ciE 'read|pars|invalid|cannot|broken'; true; }
bl1() { [ "$(bl)" -ge 1 ]; }
need "A07-AC-5: the unreadable graph is logged" 15 bl1
ticks 4
chk "A07-AC-5: a graph with adoption it cannot parse: the triage waits (issues.py is not asked)" test ! -e "$A07/issues.called"
chk "A07-AC-5: no triage session starts" test ! "$(a07_logged /noodlebot:triage && echo y)"
chk "A07-AC-5: no adoption session starts" test ! "$(a07_logged /noodlebot:adopt && echo y)"
chk "A07-AC-5: the problem is logged once (however many ticks)" test "$(bl)" = 1
a07_stop
loop_end
