#!/bin/bash
# S07: the start queue. Part of the end-to-end test of scheduler/loop.sh (fixture: testdata/lib/loop-s07.sh). Phase R1.
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"   # the runner runs *.test.sh with sh, except loop.test.sh
. "$(dirname "$0")/testdata/lib/loop-prelude.sh"
. "$src/testdata/lib/loop-s07.sh"

# R1: neither the competing fresh node nor the starvation limit is in play: the resume goes before B01. While the gap has
# not passed after A02's start, the idle session is neither stopped nor resumed.
qresetup R1
qseed qa node/A02 100; qseed qb node/B01 50
# qa tick 2: live at qb's turns through a loaded tick, and its next tick after A02's start still asks within the gap the
# checks name (8 s; spec PR #115); qb tick 3 (see the fixture)
qboth 2 3 SCHED_START_GAP=8 SCHED_STARVE=3600
qcompete A02 B01
qopen
qwait_n 10 1
# A02's log has the rejection, and the loop has ticked on it: its next tick listed A02 as a resumed unit (it found the
# idle session), asked for a turn and ended (one more tick began). That tick asked while the gap of 8 s since A02's start
# had not passed: had the gap passed, the resume (first in the order) would have started in it.
qrejected() { grep -q rate_limit_event "$qd/state/qa/node/A02/session.jsonl" 2>/dev/null; }
qwait 5 qrejected; qwait 8 qlisted qa A02:resumed; qticks 1
pid_a=$(qpid)
qok "S07-AC-6: (precondition) A02 started first, and its log has the usage-limit rejection" sh -c "[ \"\$(sed -n 1p '$q/starts.log' | awk '{ print \$3 }')\" = A02 ] && grep -q rate_limit_event '$qd/state/qa/node/A02/session.jsonl'"
qok "S07-AC-6: while the gap has not passed the idle session is not resumed (no resume start)" test "$(qn)" = 1
qok "S07-AC-6: while the gap has not passed the idle session is not stopped (same process, still alive, no session.rc)" sh -c "[ -n '$pid_a' ] && kill -0 '$pid_a' 2>/dev/null && [ ! -e '$qd/state/qa/node/A02/session.rc' ] && [ ! -e '$qd/state/qa/node/A02/resumed' ]"
qwait_n 24 3; wait_until 5 qev_ge 2; wait_until 5 qres_logged
qok "S07-AC-6: the resume goes before the fresh node (resumed unit before fresh S): A02, then its resume, then B01" test "$(qseq)" = "A02 A02.r B01"
qok "S07-AC-6: the resume start is a gap (8 s) after A02's start, and B01 a gap after the resume" qgap_n 3 7.2
qok "S07-AC-6: the idle session was resumed in its own process: a new session pid" sh -c "[ -n '$pid_a' ] && [ \"\$(cat '$qd/state/qa/node/A02/session.pid')\" != '$pid_a' ]"
qok "S07-AC-6: the node's starts is unchanged by the resume (1)" test "$(cat "$qd/state/qa/node/A02/starts" 2>/dev/null)" = 1
qok "S07-AC-6: the resume was done as S06 says (status log: resuming session A02 ... start not counted)" qres_has 'after the usage limit.*start not counted'
qok "S07-AC-6: the resume's event carries the turn text: kind resumed and its wait" qres_has '; turn: resumed, waited [^,;]+'
qok "S07-AC-6: the resume's event names the unit that waited longer and still waited (B01)" qres_has 'ahead of .*qb/B01'
qok "S07-AC-6: the resume event has no starvation note (nobody was past the limit)" test -n "$(qresev)" -a -z "$(qresev | grep -i starvation)"
qstop

loop_end
