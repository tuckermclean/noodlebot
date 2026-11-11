#!/bin/bash
# S07: the start queue. Part of the end-to-end test of scheduler/loop.sh (fixture: testdata/lib/loop-s07.sh). Phase A.
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"   # the runner runs *.test.sh with sh, except loop.test.sh
. "$(dirname "$0")/testdata/lib/loop-prelude.sh"
. "$src/testdata/lib/loop-s07.sh"

# -- Phase A: five ready units, throttle open: order, spacing (gap 2), each unit once by its own loop, the events
# Units: a triage (#7) and A02 (M), A03 (L, waited longest but under the limit) in qa; B01 (S), B04 (L) in qb.
qsetup A "A02:M A03:L" "B01:S B04:L"
echo '[{"number": 7}]' >"$q/issues.qa.json"
qseed qa issue/7 100; qseed qa node/A02 100; qseed qa node/A03 300; qseed qb node/B01 100; qseed qb node/B04 100
qboth 1 1 SCHED_START_GAP=2 SCHED_STARVE=3600
qopen
qrun_until 30 5
qok "S07-AC-1: five ready units, throttle open: exactly five sessions start, none twice" test "$(qn)" = 5 -a "$(sort "$q/starts.log" | awk '{ print $3 }' | sort -u | wc -l)" = 5
qok "S07-AC-1: every unit is started by the loop of its repository" test "$(qpairs)" = "qa:A02 qa:A03 qa:t7 qb:B01 qb:B04"
qok "S07-AC-1: one start per turn: the five starts are at least SCHED_START_GAP (2 s) apart (the sessions' clocks)" qgap_n 5 1.7
qok "S07-AC-1: the status logs' five start times are at least the gap less a second apart" test "$(qlogtimes | wc -l)" = 5
qok "S07-AC-1: the status logs' start times are at least a second apart (whole seconds, gap 2)" qlog_gap_ok 1
qok "S07-AC-2: the order is the triage and S, then M, then the Ls (the longer wait first)" test "$(qseq)" = "t7 B01 A02 A03 B04"
qok "S07-AC-3: starts.json and both waiting.json exist and every sample of them was well-formed JSON" test "$qjson_n" -ge 6 -a "$qjson_bad" = 0 -a -e "$qd/state/starts.json" -a -e "$qd/state/qa/waiting.json" -a -e "$qd/state/qb/waiting.json"
for u in 'triage of #7 ' 'A02 ' 'A03 ' 'B01 ' 'B04 '; do
	qok "S07-AC-5: ${u% } has exactly one start event" test "$(qev "$u" | wc -l)" = 1
done
qok "S07-AC-5: the triage's event names its kind and wait" qev_has 'triage of #7 ' '; turn: triage, waited [^,;]+'
qok "S07-AC-5: B01's event names its Size (S) and wait" qev_has 'B01 ' '; turn: S, waited [^,;]+'
qok "S07-AC-5: A02's event names its Size (M) and wait" qev_has 'A02 ' '; turn: M, waited [^,;]+'
qok "S07-AC-5: A03's event names its Size (L) and wait" qev_has 'A03 ' '; turn: L, waited [^,;]+'
qok "S07-AC-5: the triage's event names A03, which had waited longer and still waited" qev_has 'triage of #7 ' 'ahead of .*A03'
qok "S07-AC-5: B01's event names A03 of the other repository (qa/A03)" qev_has 'B01 ' 'ahead of .*qa/A03'
qok "S07-AC-5: A02's event names A03 too" qev_has 'A02 ' 'ahead of .*A03'
qok "S07-AC-5: A03 went ahead of nobody that had waited longer: its event has turn but no 'ahead of'" qev_hasnt 'A03 ' 'ahead of'
qok "S07-AC-5: each of the five events carries a turn (nobody was past the starvation limit)" test "$(qev '' | grep -c '; turn: ')" = 5
qok "S07-AC-5: no start event mentions the starvation limit" test "$(qev '' | grep -ci starvation)" = 0
qok "S07-AC-5: a started unit's waiting record is removed" sh -c "[ ! -e '$qd/state/qa/issue/7/waiting' ] && [ ! -e '$qd/state/qa/node/A02/waiting' ] && [ ! -e '$qd/state/qa/node/A03/waiting' ] && [ ! -e '$qd/state/qb/node/B01/waiting' ] && [ ! -e '$qd/state/qb/node/B04/waiting' ] && [ $(qn) = 5 ]"
qstop


loop_end
