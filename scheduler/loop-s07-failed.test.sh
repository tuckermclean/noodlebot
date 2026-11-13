#!/bin/bash
# S07: the start queue. Part of the end-to-end test of scheduler/loop.sh (fixture: testdata/lib/loop-s07.sh). Phases E and F.
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"   # the runner runs *.test.sh with sh, except loop.test.sh
. "$(dirname "$0")/testdata/lib/loop-prelude.sh"
. "$src/testdata/lib/loop-s07.sh"

# -- Phase E: a unit whose start fails does not hold the queue
# A02 (S, qa) cannot start: its branch is checked out in another worktree, so the worktree for it cannot be made.
# A03 (L, qa) is next in the order; B01 (L, qb) after it.
qsetup E "A02:S A03:L" "B01:L"
git -C "$qd/repos/qa" worktree add -q -b node/A02-u-A02 "$q/blocker" origin/main
qseed qa node/A02 100; qseed qa node/A03 100; qseed qb node/B01 100
# tick 3 (qa): live at qb's turns through a loaded tick, else B01 (tied with A03, after it by the repository's name) takes
# the turn; tick 2 (qb) asks alone for B01 (see the fixture). Once A03 has started the throttle holds until the blocker is
# gone and qa has listed A02 again (no longer given back): otherwise every turn of qa after the gap fails A02 again and
# gives it back, and qb's next turn takes B01 before it. Gap 8 s (no check names it): the hold comes as soon as A03's
# session has logged, and qa's next tick reads it; only a qb tick that read the throttle open just before the hold can ask
# again, and its turn would need the gap to have passed since A03's turn (and qa not yet to have listed A02 again). That
# is more than 8 s of a tick's work between reading the throttle and asking; the old gap of 4 s was within a loaded tick
# (the work of a tick is several seconds under load).
qboth 3 2 SCHED_START_GAP=8 SCHED_STARVE=3600
qcompete "A02 A03" B01
qopen
qwait 10 qhave A03; qhold; wait_until 15 qev_ge 1; qticks 1
qok "S07-AC-4: the failed unit (A02) does not hold the queue: the next in the order (A03) starts, and only it" test "$(qseq)" = "A03"
qok "S07-AC-4: the failed start is logged" grep -q 'worktree for A02 failed' "$(qlog qa)"
# "in the same tick" (the old bound of 1 s between the two lines was a tick of 1 s): A03 started after the failure, and the
# tick that started A03 (its heartbeat, qhb) had begun by the second of the failure. A start in a later tick has a later
# heartbeat, when no pause of qa ends early between the failure tick and any later tick that might start A03 (loop.sh's
# pause() returns at once when one of qa's sessions exits or a marker of qa changes; qa runs no session before A03 starts
# and the test touches no marker of qa in between), so that a tick begins at least SCHED_TICK (3 s) after the second in
# which the one before ended.
qok "S07-AC-4: the next unit starts in the same tick as the failure" sh -c "f=\$(grep -m1 'worktree for A02 failed' '$(qlog qa)' | awk '{print \$1}'); s=\$(grep -m1 '; started A03' '$(qlog qa)' | awk '{print \$1}'); h='$(qhb A03)'; [ -n \"\$f\" ] && [ -n \"\$s\" ] && [ -n \"\$h\" ] && d=\$((\$(date -d \$s +%s) - \$(date -d \$f +%s))) && [ \$d -ge 0 ] && [ \$(date -d \$f +%s) -ge \$h ]"
qok "S07-AC-4: the failed unit still has its waiting record" test -e "$qd/state/qa/node/A02/waiting"
git -C "$qd/repos/qa" worktree remove --force "$q/blocker"; git -C "$qd/repos/qa" branch -q -D node/A02-u-A02
qa_relisted() { qlisted qa A02 && grep -qF '"gaveback": []' "$qd/state/qa/waiting.json"; }
qwait 8 qa_relisted; qopen
qwait_n 14 3; wait_until 15 qev_ge 3
qok "S07-AC-4: the failed unit is tried again from the next tick, and starts (the S node before B01)" test "$(qseq)" = "A03 A02 B01"
qstop

# -- Phase F: a stopped loop does not block a live one
# qa's loop (with the oldest unit, A03) is killed after its first tick; qb's two units start once its heartbeat is three ticks old.
qsetup F "A03:L" "B01:L B04:L"
qseed qa node/A03 300; qseed qb node/B01 100; qseed qb node/B04 100
# qa takes no turn (tick 1: its heartbeat is old 3 s after it is killed); qb (tick 2) asks alone (see the fixture).
# qa is killed once both loops have listed their units.
qboth 1 2 SCHED_START_GAP=4 SCHED_STARVE=3600
qcompete A03 "B01 B04"
{ kill -KILL "${qp[qa]}"; wait "${qp[qa]}"; } 2>/dev/null
qopen
qwait_n 15 2; wait_until 15 qev_ge 2
qok "S07-AC-4: a loop whose heartbeat is older than three ticks is left out: the live loop's units start" test "$(qseq)" = "B01 B04"
qok "S07-AC-4: and the queue still spaces them by the gap (4 s)" qgap_n 2 3.6
qstop


loop_end
