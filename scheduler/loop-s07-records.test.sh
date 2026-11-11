#!/bin/bash
# S07: the start queue. Part of the end-to-end test of scheduler/loop.sh (fixture: testdata/lib/loop-s07.sh). Phase C.
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"   # the runner runs *.test.sh with sh, except loop.test.sh
. "$(dirname "$0")/testdata/lib/loop-prelude.sh"
. "$src/testdata/lib/loop-s07.sh"

# -- Phase C: the throttle holds from the second turn; the waiting records; the next start comes at the first turn after it opens
# qa: triage #7, A02 (M), A03 (L); qb: triage #9, B01 (S), B04 (L). No seeds: the loops write the records.
qsetup C "A02:M A03:L" "B01:S B04:L"
echo '[{"number": 7}]' >"$q/issues.qa.json"; echo '[{"number": 9}]' >"$q/issues.qb.json"
QENV="SCHED_START_GAP=1 SCHED_STARVE=3600"
qopen
t_c0=$(date +%s)
qloop qa 1 $QENV; qwait 8 qfirst qa; qloop qb 1 $QENV
qwait 12 qhave t7; qhold
qticks 3
qok "S07-AC-1: the throttle holding from the second turn: only the first unit started" test "$(qseq)" = "t7"
qrecs() { local f; for f in qa/node/A02 qa/node/A03 qb/node/B01 qb/node/B04 qb/issue/9; do [ -e "$qd/state/$f/waiting" ] || return 1; done; }
qwait 3 qrecs
qrecs_valid() { local f r; for f in qa/node/A02 qa/node/A03 qb/node/B01 qb/node/B04 qb/issue/9; do r=$(cat "$qd/state/$f/waiting" 2>/dev/null) || return 1; case $r in ''|*[!0-9]*) return 1 ;; esac; [ "$r" -ge $((t_c0 - 1)) ] && [ "$r" -le "$(date +%s)" ] || return 1; done; }
qok "S07-AC-5: each unit found waiting has a record (epoch seconds, no earlier than the loop's start)" qrecs_valid
qok "S07-AC-5: the record of the started triage is removed" test ! -e "$qd/state/qa/issue/7/waiting"
ra02=$(qrec qa node/A02); ra03=$(qrec qa node/A03); rb04=$(qrec qb node/B04); rb9=$(qrec qb issue/9)
touch "$HOME/STOP-qa"; qwait 6 sh -c "! kill -0 ${qp[qa]} 2>/dev/null"; rm -f "$HOME/STOP-qa"
qloop qa 1 $QENV; qwait 8 sh -c "[ \$(grep -c 'loop started' '$(qlog qa)') -ge 2 ]"; qticks 2
qok "S07-AC-5: a record survives a loop restart with its time unchanged" test -n "$ra02" -a "$(qrec qa node/A02)" = "$ra02" -a "$(qrec qa node/A03)" = "$ra03"
echo "Q1: q" >"$qd/state/qa/node/A03/QUESTION.md"; touch "$qd/state/qb/node/B04/FAILED"; echo '[]' >"$q/issues.qb.json"
qgone_after() { [ -n "$2" ] || return 1; qwait 5 test ! -e "$1"; }
qok "S07-AC-5: a record is removed when the node gets a QUESTION.md" qgone_after "$qd/state/qa/node/A03/waiting" "$ra03"
qok "S07-AC-5: a record is removed when the node gets a FAILED" qgone_after "$qd/state/qb/node/B04/waiting" "$rb04"
qok "S07-AC-5: a record is removed when the issue's label is removed" qgone_after "$qd/state/qb/issue/9/waiting" "$rb9"
echo "Q1: a" >"$qd/state/qa/node/A03/ANSWER.md"; rm -f "$qd/state/qb/node/B04/FAILED"
qnewer() { [ -n "$2" ] && qwait 5 test -e "$1" && [ "$(cat "$1")" -gt "$2" ]; }
qok "S07-AC-5: an answered node's wait restarts: a new record, later than the old" qnewer "$qd/state/qa/node/A03/waiting" "$ra03"
qok "S07-AC-5: a node that lost its FAILED waits anew: a new record, later than the old" qnewer "$qd/state/qb/node/B04/waiting" "$rb04"
qopen; t_open=$(date +%s.%N)
qwait_n 8 2; wait_until 5 qev_ge 2
qsecond_soon() { [ "$(sort -n "$q/starts.log" | sed -n 2p | awk '{ print $3 }')" = B01 ] && awk -v a="$t_open" -v b="$(qt B01)" 'BEGIN { exit !(b - a >= 0 && b - a <= 2.6) }'; }
qok "S07-AC-1: the next unit (the S node) starts at the first turn after the throttle opens, within 2.6 s" qsecond_soon
qok "S07-AC-5: the started node's record is removed" test ! -e "$qd/state/qb/node/B01/waiting" -a -n "$ra03"
qstop


loop_end
