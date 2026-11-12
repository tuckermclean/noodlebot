#!/bin/bash
# S07: the start queue. Part of the end-to-end test of scheduler/loop.sh (fixture: testdata/lib/loop-s07.sh). Phase G.
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"   # the runner runs *.test.sh with sh, except loop.test.sh
. "$(dirname "$0")/testdata/lib/loop-prelude.sh"
. "$src/testdata/lib/loop-s07.sh"

# -- Phase G: one triage or update per repository, SCHED_MAX, running sessions untouched
# G1: two labelled issues and a node in qa, no cap: the second triage waits until the first ends.
qsetup G1 "A02:S" "B01:S"
echo '[{"number": 7}, {"number": 8}]' >"$q/issues.qa.json"
QENV="SCHED_START_GAP=1 SCHED_STARVE=3600"
# tick 2: a loop asking alone stays live through a loaded tick (see the fixture)
qloop qa 2 $QENV
qwait_n 12 2; qticks 3
qok "S07-AC-7: the triage and the node start (the triage first)" test "$(qseq)" = "t7 A02"
qok "S07-AC-7: a second labelled issue does not start while the first triage runs" sh -c "! grep -q ' t8\$' '$q/starts.log'"
qok "S07-AC-5: the second issue does not wait to start while the triage holds the slot (no record)" test ! -e "$qd/state/qa/issue/8/waiting" -a "$(qn)" = 2
qok "S07-AC-7: the running node is not stopped by the queue" qalive qa/node/A02
touch "$q/end.t7"
qwait 12 qhave t8
qok "S07-AC-7: the second triage starts once the first has ended" test "$(qseq)" = "t7 A02 t8"
qok "S07-AC-7: the running node session is still running" qalive qa/node/A02
qstop
# G2: SCHED_MAX=2 in qa with three nodes.
qsetup G2 "A02:S A03:M A04:L" "B01:S"
qloop qa 2 SCHED_START_GAP=1 SCHED_STARVE=3600 SCHED_MAX=2
qwait_n 12 2; qticks 3
qok "S07-AC-7: SCHED_MAX=2 caps the repository's sessions at two, started in the queue's order" test "$(qseq)" = "A02 A03" -a "$(qn)" = 2
qok "S07-AC-1: the two starts of a capped repository are at least the gap apart" qgap_n 2 0.6
qok "S07-AC-7: the sessions the cap lets run are not stopped" bash -c "$(declare -f qalive); qd='$qd'; qalive qa/node/A02 && qalive qa/node/A03"
qok "S07-AC-7: at the cap the third node does not wait to start (no record)" test ! -e "$qd/state/qa/node/A04/waiting" -a "$(qn)" = 2
touch "$q/end.A02"
qwait 12 qhave A04
qok "S07-AC-7: when a session ends the cap has room: the third node starts" test "$(qseq)" = "A02 A03 A04"
qstop


loop_end
