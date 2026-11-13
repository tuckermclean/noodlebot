#!/bin/bash
# S07: the start queue. Part of the end-to-end test of scheduler/loop.sh (fixture: testdata/lib/loop-s07.sh). Phases L2, J0 and J1.
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"   # the runner runs *.test.sh with sh, except loop.test.sh
. "$(dirname "$0")/testdata/lib/loop-prelude.sh"
. "$src/testdata/lib/loop-s07.sh"

# -- Phase L2: a loop restarted with SCHED_RAMP=0 over its old waiting.json must not hold the other loop
qsetup L2 "A03:L" "B01:L"
qseed qa node/A03 300; qseed qb node/B01 100
QENV="SCHED_START_GAP=1 SCHED_STARVE=3600"
# tick 2: qa's heartbeat stays fresh (6 s) through a loaded tick, so its old list would count; qb asks alone (see the fixture)
qhold; qloop qa 2 $QENV; qwait 8 qfirst qa
qwait 5 qlisted qa A03
qok "S07-AC-3: (precondition) qa listed A03 in its waiting.json" test -e "$qd/state/qa/waiting.json"
touch "$HOME/STOP-qa"; qwait 6 sh -c "! kill -0 ${qp[qa]} 2>/dev/null"; rm -f "$HOME/STOP-qa"
qloop qa 2 $QENV SCHED_RAMP=0; qwait 8 sh -c "[ \$(grep -c 'loop started' '$(qlog qa)') -ge 2 ]"
# the restarted loop (SCHED_RAMP=0) has ticked and taken its old waiting.json away (the old fixed sleep of 1.5 s)
qwait 8 test ! -e "$qd/state/qa/waiting.json"
qloop qb 2 $QENV SCHED_THROTTLE=0
qwait 12 qhave B01; wait_until 5 qev_ge 1
qok "S07-AC-4: a loop restarted with SCHED_RAMP=0 (its throttle holding) does not hold the other loop with its old waiting.json: B01 starts" qhave B01
qok "S07-AC-7: the SCHED_RAMP=0 loop under a throttle hold starts nothing" test "$(qseq)" = "B01"
qstop

# -- Phase J1/J0: one triage or update per repository. A triage that cannot start (its issue has used 2 starts) does not keep
# the spec-PR updates out of the slot: the next candidate starts; and only one at a time. J0 is the same with SCHED_RAMP=0 (as before).
qslot() { # <tag> <label> <tick> [VAR=value...]
	local tag=$1 lab=$2 tk=$3; shift 3
	qsetup "$tag" "A02:S" "B01:S"; qghx
	mkdir -p "$qd/state/qa/node/A02" "$qd/state/qa/issue/7"; touch "$qd/state/qa/node/A02/FAILED"
	echo 2 >"$qd/state/qa/issue/7/starts"; echo '[{"number": 7}]' >"$q/issues.qa.json"
	git -C "$q/qa.git" branch spec/u1 main; git -C "$q/qa.git" branch spec/u2 main
	printf '31 spec/u1 oid31 true CONFLICTING\n32 spec/u2 oid32 true CONFLICTING\n' >"$q/open.qa.tsv"
	qloop qa "$tk" SCHED_START_GAP=1 SCHED_STARVE=3600 "$@"
	qwait 12 qhave t31; qticks 3
	qok "S07-AC-7: $lab: a triage that cannot start does not keep the spec-PR updates out of the slot: the next candidate (PR 31) starts, and only it" test "$(qseq)" = "t31"
	qok "S07-AC-7: $lab: one triage or update at a time: the update session runs" qalive qa/pr/31
	touch "$q/end.t31"
	qwait 12 qhave t32; qticks 1
	qok "S07-AC-7: $lab: when the update ends the next candidate (PR 32) starts, once" test "$(grep -c ' t32$' "$q/starts.log")" = 1
	qstop
}
# J0 takes no turn (no queue): tick 1; J1's loop asks alone: tick 2, live through a loaded tick (see the fixture)
qslot J0 "SCHED_RAMP=0" 1 SCHED_RAMP=0
qslot J1 "SCHED_RAMP=1" 2 SCHED_RAMP=1


loop_end
