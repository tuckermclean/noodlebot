#!/bin/bash
# G02: the update's end with rc 0 and when it starts again (main moves, the PR's head moves). Part of the end-to-end test of scheduler/loop.sh (fixture: testdata/lib/loop-g02.sh).
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"   # the runner runs *.test.sh with sh, except loop.test.sh
. "$(dirname "$0")/testdata/lib/loop-prelude.sh"
. "$src/testdata/lib/loop-g02.sh"

# node N05's session runs (the fake one), before the loop starts
mkdir -p "$state/node/N05"
sh "$G02/fake/run-session.sh" x N05 </dev/null >/dev/null 2>&1 &
g02_np=$!; pids+=("$g02_np"); echo "$g02_np" >"$state/node/N05/session.pid"

# The state the main run is in when it comes to these cases: the throttle open (an allowed window).
g02_rl 0.01 $(($(date +%s) + 7200))
g02_loop 0
# the state of the main part when it comes to these cases: PR 201 has its update running (held), N05 has its session, PR 205 waits
# D20: waits that stand for loop ticks count the loop's ticks (g02_tickwait, loop-g02.sh), not seconds: a loaded tick takes 4-8 s (11.4 s in D05).
g02_tickwait 5 g02_runsis 201 1
if [ "$(g02_runs 201)" = 1 ]; then
	# N05's session ends: its PR's update starts
	kill "$g02_np" 2>/dev/null; rm -f "$state/node/N05/session.pid"
	ok "G02-AC-1: when N05's session is gone, PR 205 gets its update" g02_tickwait 4 g02_runsis 205 1
	# seconds are right here: the fake's own two writes (the run count, then the log line) with no loop tick between them
	waitf 5 grep -qF "| $g02_wt/pr-205 | node/N05-epsilon" "$G02_GD/claude.log" || fail "D20 setup: the fake's claude.log line of PR 205's run (written just after the run is counted)"
	ok "G02-AC-1: it runs in worktrees/<name>/pr-205 on node/N05-epsilon" grep -qF "| $g02_wt/pr-205 | node/N05-epsilon" "$G02_GD/claude.log"
	# seconds are right here: the loop logs the start right after launch, before the fake can count its run (waited for above)
	ok "G02-AC-1: and it is start 1 of 2, one event" waitf 3 g02_evis 205 'start 1 of 2' 1
	wait_ticks 2 || fail "D20 setup: the loop's heartbeat did not change twice (2 ticks) before the check that N05's session does not start"
	ok "G02-AC-1: the node's session (N05) does not start while its update runs" sh -c "! grep -qE '^node N05 ' '$G02_GD/claude.log'"
	rm -f "$G02_GD/hold.205"
	g02_tickwait 4 g02_evis 205 'rc 0' 1 || fail "D20 setup: PR 205's update did not end with one rc 0 event (4 ticks)"
	g02_prs 205 MERGEABLE
	# G02-AC-2: rc 0
	rm -f "$G02_GD/hold.201"
	ok "G02-AC-2: an update ending with rc 0 is one status-log event" g02_tickwait 4 g02_evis 201 'rc 0' 1
	# seconds are right here: update_ended removes the worktree before it logs the rc 0 waited for above, no loop tick between
	ok "G02-AC-2: and its worktree is removed" waitf 3 test ! -d "$g02_wt/pr-201"
	wait_ticks 3 || fail "D20 setup: the loop's heartbeat did not change 3 times (3 ticks) before the check that PR 201 is not started again"
	ok "G02-AC-2: after rc 0 it is not started again while main and the PR's head stay" g02_runsis 201 1
	g02_mvref main
	ok "G02-AC-2: when main moves, it is started again (start 1 of 2 again)" g02_tickwait 4 g02_runsis 201 2
	g02_tickwait 4 g02_evis 201 'rc 0' 2 || fail "D20 setup: PR 201's second update did not end with its second rc 0 event (4 ticks)"
	wait_ticks 2 || fail "D20 setup: the loop's heartbeat did not change twice (2 ticks) before the PR's head moves"
	g02_mvref node/N01-alpha
	ok "G02-AC-2: when only the PR's head moves, it is started again" g02_tickwait 4 g02_runsis 201 3
	g02_tickwait 4 g02_evis 201 'rc 0' 3 || fail "D20 setup: PR 201's third update did not end with its third rc 0 event (4 ticks)"
	ok "G02-AC-2: each start and each end is one event (3 starts, 3 ends)" sh -c "[ \"\$(grep -E 'PR #201([^0-9]|\$)' '$state/status.log' | grep -cE 'start [12] of 2')\" = 3 ] && [ \"\$(grep -E 'PR #201([^0-9]|\$)' '$state/status.log' | grep -cE 'rc 0')\" = 3 ]"
else
	fail "G02-AC-1/2: no node-PR update started, so the cases that need a running update were not run"
fi
g02_stop

loop_end
