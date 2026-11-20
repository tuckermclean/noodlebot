#!/bin/bash
# G02: review1d #5: the production default, SCHED_RAMP=1. Part of the end-to-end test of scheduler/loop.sh (fixture: testdata/lib/loop-g02.sh).
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"   # the runner runs *.test.sh with sh, except loop.test.sh
. "$(dirname "$0")/testdata/lib/loop-prelude.sh"
. "$src/testdata/lib/loop-g02.sh"
. "$src/testdata/lib/loop-g02-review.sh"

# The state the main run is in when it comes to these cases: the throttle open (an allowed window), the PRs of the main part not wanting an update.
g02_rl 0.01 $(($(date +%s) + 7200))
g02_prs 201 MERGEABLE; g02_prs 205 MERGEABLE
: >>"$state/status.log"   # the log of the earlier cases of the main run (g02_lines below counts its lines)
# review1d #5: the production default, SCHED_RAMP=1 (the queue, turn.py). 254: the throttle holds it, then it
# starts through a turn; 255 and 256 with SCHED_MAX=1: one at a time.
g02_rl 0.99 $(($(date +%s) + 10800))
touch "$G02_GD/hold.254"
g02_prs 254 CONFLICTING
g02_lines=$(wc -l <"$state/status.log")
# D17: SCHED_TICK=2 (g02b_loop's 4th argument; review2 keeps tick 1). turn.py counts a loop live only while its heartbeat is
# less than 3 x tick old (6 s at tick 2), and the loop asks at the end of its tick. Loaded (2 `yes` per pinned CPU) a tick's work was
# about 2-5 s and the heartbeat spacing (work plus a pause of up to a tick) 4-5 s; an ask that finds the loop stale only puts the turn off to a later tick.
g02r_tick=2
g02b_loop 0 "$g02_data" 1 $g02r_tick
ok "G02-AC-1 (review1d #5, ramp=1): the throttle engages" waitf 8 sh -c "tail -n +$((g02_lines + 1)) '$state/status.log' | grep -q 'throttle engaged'"
wait_ticks 3 || fail "D17 setup: the loop did not tick 3 times (in loop-g02-review3.test.sh)"
ok "G02-AC-1 (review1d #5, ramp=1): while the throttle holds, the CONFLICTING bot node PR (254) gets no update" g02_runsis 254 0
g02_rl 0.01 $(($(date +%s) + 14400))
# D17: the waits for a turn-granted start (30 s) and for the end's log line (15 s) grew with the tick: worst case about 2 x work + 2 s
# at tick 2, more if an ask finds the loop stale. They are time-outs on observed conditions, so a passing run costs nothing.
ok "G02-AC-1 (review1d #5, ramp=1): when the throttle is released, 254 gets its update session" waitf 30 g02_runsis 254 1
ok "G02-AC-1 (review1d #5, ramp=1): in worktrees/<name>/pr-254 on its branch, prompt /noodlebot:node --update 254" waitf 3 grep -qF "nupd 254 run 1 /noodlebot:node --update 254 | $g02_wt/pr-254 | node/N34-ee" "$G02_GD/claude.log"
ok "G02-AC-1 (review1d #5, ramp=1): its start is one event, start 1 of 2, granted by a turn (turn.py)" waitf 3 sh -c "grep -E 'PR #254([^0-9]|\$)' '$state/status.log' | grep -E 'start 1 of 2' | grep -qE 'turn: '"
ok "G02-AC-1 (review1d #5, ramp=1): and it is one start event" g02_evis 254 'start 1 of 2' 1
rm -f "$G02_GD/hold.254"
waitf 15 g02_evis 254 'rc 0' 1 || fail "D17 setup: 254's update session logs rc 0 (in loop-g02-review3.test.sh)"
g02_prs 254 MERGEABLE
g02_stop
g02_prs 255 CONFLICTING; g02_prs 256 CONFLICTING
touch "$G02_GD/hold.255" "$G02_GD/hold.256"
g02b_loop 1 "$g02_data" 1 $g02r_tick
ok "G02-AC-1 (review1d #5, ramp=1): with SCHED_MAX=1 an update starts" waitf 30 sh -c "[ \$(( \$(cat '$G02_GD/runs.255' 2>/dev/null || echo 0) + \$(cat '$G02_GD/runs.256' 2>/dev/null || echo 0) )) -ge 1 ]"
wait_ticks 3 || fail "D17 setup: the loop did not tick 3 times (in loop-g02-review3.test.sh)"
ok "G02-AC-1 (review1d #5, ramp=1): updates count toward SCHED_MAX: the other one does not start while it runs" sh -c "[ \$(( \$(cat '$G02_GD/runs.255' 2>/dev/null || echo 0) + \$(cat '$G02_GD/runs.256' 2>/dev/null || echo 0) )) = 1 ]"
if [ -s "$G02_GD/runs.255" ]; then g02_first=255 g02_second=256; else g02_first=256 g02_second=255; fi
rm -f "$G02_GD/hold.$g02_first"
ok "G02-AC-1 (review1d #5, ramp=1): the other one starts when the first has ended" waitf 30 g02_runsis $g02_second 1
rm -f "$G02_GD/hold.$g02_second"
waitf 15 g02_evis $g02_second 'rc 0' 1 || fail "D17 setup: the second update session logs rc 0 (in loop-g02-review3.test.sh)"
g02_prs 255 MERGEABLE; g02_prs 256 MERGEABLE
g02_stop

loop_end
