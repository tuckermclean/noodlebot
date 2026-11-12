#!/bin/bash
# S07: the start queue. Part of the end-to-end test of scheduler/loop.sh (fixture: testdata/lib/loop-s07.sh). Phase B.
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"   # the runner runs *.test.sh with sh, except loop.test.sh
. "$(dirname "$0")/testdata/lib/loop-prelude.sh"
. "$src/testdata/lib/loop-s07.sh"

# -- Phase B: an M node past the starvation limit goes first; no SCHED_START_GAP: the gap is the largest tick (qb's 2 s)
qsetup B "A02:M" "B01:S"
echo '[{"number": 7}]' >"$q/issues.qa.json"
qseed qa issue/7 100; qseed qa node/A02 7200; qseed qb node/B01 100
# the ticks stay 1 and 2: the gap check names the largest tick (2 s); see D05's open question on qa's tick 1 under load
qboth 1 2 SCHED_STARVE=3600
qcompete "#7 A02" B01
qopen
qwait_n 25 3; wait_until 5 qev_ge 3
qok "S07-AC-2: an M node past SCHED_STARVE starts before the triage and the S node" test "$(qseq)" = "A02 t7 B01"
qok "S07-AC-5: its event says the starvation limit put it first, and its wait (2 h)" qev_has 'A02 ' '; turn: M, waited 2h.*starvation'
qok "S07-AC-5: the triage, which did not pass the limit, has no starvation note" qev_hasnt 'triage of #7 ' starvation
qok "S07-AC-5: B01, which did not pass the limit, has no starvation note" qev_hasnt 'B01 ' starvation
qok "S07-AC-1: without SCHED_START_GAP the gap is the largest SCHED_TICK of the two loops (2 s)" qgap_ok 1.7
qstop

loop_end
