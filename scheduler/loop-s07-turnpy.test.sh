#!/bin/bash
# S07: the start queue. Part of the end-to-end test of scheduler/loop.sh (fixture: testdata/lib/loop-s07.sh). Phases H and L1.
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"   # the runner runs *.test.sh with sh, except loop.test.sh
. "$(dirname "$0")/testdata/lib/loop-prelude.sh"
. "$src/testdata/lib/loop-s07.sh"

# -- Phase H: turn.py fails: no session starts that tick, the status log says so; running sessions go on
qsetup H "A02:S A03:L" "B01:S"
if [ -f "$qnb/scheduler/turn.py" ]; then cp "$qnb/scheduler/turn.py" "$q/turn.real.py"; else : >"$q/turn.real.py"; fi
printf '#!/usr/bin/env python3\nimport sys\nsys.stderr.write("fake turn.py failure\\n")\nsys.exit(1)\n' >"$q/turn.fake.py"
swap_turn() { cp "$1" "$qnb/scheduler/turn.py.new" && mv "$qnb/scheduler/turn.py.new" "$qnb/scheduler/turn.py"; }
# tick 2: a loop asking alone stays live through a loaded tick (see the fixture)
qloop qa 2 SCHED_START_GAP=1 SCHED_STARVE=3600
qwait 8 qhave A02
swap_turn "$q/turn.fake.py"
qticks 4
qok "S07-AC-7: turn.py failing: no session starts that tick or the next ones (A03 waits)" test "$(qseq)" = "A02"
qok "S07-AC-7: turn.py failing: the status log says so" grep -qi 'turn\.py' "$(qlog qa)"
qok "S07-AC-7: turn.py failing: the running session goes on" qalive qa/node/A02
swap_turn "$q/turn.real.py"
qwait 8 qhave A03
qok "S07-AC-7: turn.py working again: the waiting unit starts" test "$(qseq)" = "A02 A03"
qstop


# -- Phase L1: a loop whose tick ends before the queue (gh fails) while its heartbeat stays fresh must not hold the other loop
qsetup L1 "A03:L" "B01:L"; qghx
qseed qa node/A03 300; qseed qb node/B01 100
# tick 2: qb asks alone and stays live through a loaded tick; qa's heartbeat stays fresh (6 s) while its ticks end early,
# so its list is left out only because it is taken away (see the fixture)
qboth 2 2 SCHED_START_GAP=1 SCHED_STARVE=3600
qcompete A03 B01; touch "$q/ghfail.qa"
# qa's ticks end early and its old waiting list is taken away (the old fixed sleep of 2.5 s let that happen)
qa_listless() { grep -q 'gh pr list failed' "$(qlog qa)" && [ ! -e "$qd/state/qa/waiting.json" ]; }
qwait 8 qa_listless
qopen
qwait 12 qhave B01; wait_until 5 qev_ge 1
qok "S07-AC-4: (precondition) qa's ticks end early: its status log says gh failed" grep -q 'gh pr list failed' "$(qlog qa)"
qok "S07-AC-4: a loop whose tick ends before the queue (heartbeat fresh) does not keep its old waiting list in the order: the other loop's unit starts" qhave B01
qok "S07-AC-4: and only that unit starts (qa's tick ends before the queue)" test "$(qseq)" = "B01"
qstop


loop_end
