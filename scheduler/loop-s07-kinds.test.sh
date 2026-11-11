#!/bin/bash
# S07: the start queue. Part of the end-to-end test of scheduler/loop.sh (fixture: testdata/lib/loop-s07.sh). Phase K.
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"   # the runner runs *.test.sh with sh, except loop.test.sh
. "$(dirname "$0")/testdata/lib/loop-prelude.sh"
. "$src/testdata/lib/loop-s07.sh"

# -- Phase K: a failed issues.py next (API error) does not delete the triage's waiting record
qsetup K "A02:S" "B01:S"; qghx
mkdir -p "$qd/state/qa/node/A02"; touch "$qd/state/qa/node/A02/FAILED"
echo '[{"number": 7}]' >"$q/issues.qa.json"
qhold; qloop qa 1 SCHED_START_GAP=1 SCHED_STARVE=3600; qwait 8 qfirst qa
qwait 4 test -e "$qd/state/qa/issue/7/waiting"; rk=$(qrec qa issue/7)
touch "$q/issfail"; qticks 4
qok "S07-AC-5: a failed issues.py next keeps the triage's waiting record, its time unchanged" test -n "$rk" -a "$(qrec qa issue/7)" = "$rk"
echo '[]' >"$q/issues.qa.json"; rm -f "$q/issfail"
qgone() { qwait 5 test ! -e "$1"; }
qok "S07-AC-5: the record is removed once the issue stops waiting (label removed)" qgone "$qd/state/qa/issue/7/waiting"
echo '[{"number": 7}]' >"$q/issues.qa.json"
qnewer2() { qwait 5 test -e "$1" && [ "$(cat "$1")" -gt "$2" ]; }
qok "S07-AC-5: relabelled, the wait restarts: a new record, later than the old" qnewer2 "$qd/state/qa/issue/7/waiting" "${rk:-0}"
qstop

loop_end
