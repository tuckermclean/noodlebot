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
qboth 1 1 SCHED_START_GAP=2 SCHED_STARVE=3600
qopen
qwait 10 qhave A03; wait_until 5 qev_ge 1; qticks 1
qok "S07-AC-4: the failed unit (A02) does not hold the queue: the next in the order (A03) starts, and only it" test "$(qseq)" = "A03"
qok "S07-AC-4: the failed start is logged" grep -q 'worktree for A02 failed' "$(qlog qa)"
qok "S07-AC-4: the next unit starts in the same tick as the failure" sh -c "f=\$(grep -m1 'worktree for A02 failed' '$(qlog qa)' | awk '{print \$1}'); s=\$(grep -m1 '; started A03' '$(qlog qa)' | awk '{print \$1}'); [ -n \"\$f\" ] && [ -n \"\$s\" ] && d=\$((\$(date -d \$s +%s) - \$(date -d \$f +%s))) && [ \$d -ge 0 ] && [ \$d -le 1 ]"
qok "S07-AC-4: the failed unit still has its waiting record" test -e "$qd/state/qa/node/A02/waiting"
git -C "$qd/repos/qa" worktree remove --force "$q/blocker"; git -C "$qd/repos/qa" branch -q -D node/A02-u-A02
qwait_n 14 3; wait_until 5 qev_ge 3
qok "S07-AC-4: the failed unit is tried again from the next tick, and starts (the S node before B01)" test "$(qseq)" = "A03 A02 B01"
qstop

# -- Phase F: a stopped loop does not block a live one
# qa's loop (with the oldest unit, A03) is killed after its first tick; qb's two units start once its heartbeat is three ticks old.
qsetup F "A03:L" "B01:L B04:L"
qseed qa node/A03 300; qseed qb node/B01 100; qseed qb node/B04 100
qboth 1 1 SCHED_START_GAP=1 SCHED_STARVE=3600
{ kill -KILL "${qp[qa]}"; wait "${qp[qa]}"; } 2>/dev/null
qopen
qwait_n 15 2; wait_until 5 qev_ge 2
qok "S07-AC-4: a loop whose heartbeat is older than three ticks is left out: the live loop's units start" test "$(qseq)" = "B01 B04"
qok "S07-AC-4: and the queue still spaces them by the gap (1 s)" qgap_n 2 0.6
qstop


loop_end
