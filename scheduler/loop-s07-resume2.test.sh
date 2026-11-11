#!/bin/bash
# S07: the start queue. Part of the end-to-end test of scheduler/loop.sh (fixture: testdata/lib/loop-s07.sh). Phase R2.
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"   # the runner runs *.test.sh with sh, except loop.test.sh
. "$(dirname "$0")/testdata/lib/loop-prelude.sh"
. "$src/testdata/lib/loop-s07.sh"

# R2: B01 has waited longer than SCHED_STARVE: it goes before the resume.
qresetup R2
qseed qa node/A02 200; qseed qb node/B01 100
qboth 1 1 SCHED_START_GAP=4 SCHED_STARVE=60
qopen
qwait_n 14 3; wait_until 5 qev_ge 2; wait_until 5 qres_logged
qok "S07-AC-6: a fresh node past the starvation limit goes before the resume: A02, B01, then the resume" test "$(qseq)" = "A02 B01 A02.r"
qok "S07-AC-6: the starved node's start is a gap after A02's, the resume a gap after that" qgap_n 3 3.6
qok "S07-AC-6: the resume still leaves the node's starts unchanged (1)" test "$(cat "$qd/state/qa/node/A02/starts" 2>/dev/null)" = 1
qok "S07-AC-6: the resume's event carries the turn text (kind resumed, its wait)" qres_has '; turn: resumed, waited [^,;]+'
qstop


loop_end
