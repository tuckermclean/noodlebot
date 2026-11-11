#!/bin/bash
# S07: the start queue. Part of the end-to-end test of scheduler/loop.sh (fixture: testdata/lib/loop-s07.sh). Phase D.
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"   # the runner runs *.test.sh with sh, except loop.test.sh
. "$(dirname "$0")/testdata/lib/loop-prelude.sh"
. "$src/testdata/lib/loop-s07.sh"

# -- Phase D: both loops reach a turn at the same moment (both start together, the throttle opens for both)
qsetup D "A03:L A04:L" "B04:L B05:L"
qboth 1 1 SCHED_START_GAP=1 SCHED_STARVE=3600
qopen
qrun_until 25 4
qok "S07-AC-3: four units, two loops at the same moments: four sessions start, each unit once, by its own loop" test "$(qn)" = 4 -a "$(qpairs)" = "qa:A03 qa:A04 qb:B04 qb:B05"
qok "S07-AC-3: one unit starts between the loops per turn, not two: the four starts are at least the gap (1 s) apart" qgap_n 4 0.6
qok "S07-AC-3: starts.json and both waiting.json exist and every sample was well-formed JSON" test "$qjson_n" -ge 6 -a "$qjson_bad" = 0 -a -e "$qd/state/starts.json" -a -e "$qd/state/qa/waiting.json" -a -e "$qd/state/qb/waiting.json"
qstop
qjson_n=0 qjson_bad=0


loop_end
