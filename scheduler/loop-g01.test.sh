#!/bin/bash
# G01: update sessions for the bot's spec PRs: the throttle, one update at a time, no restart until main or the head moves. Part of the end-to-end test of scheduler/loop.sh (fixture: testdata/lib/loop-g01.sh).
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"   # the runner runs *.test.sh with sh, except loop.test.sh
. "$(dirname "$0")/testdata/lib/loop-prelude.sh"
. "$src/testdata/lib/loop-g01.sh"

# The state the throttle case (loop-g01-throttle.test.sh) leaves the main run in: an allowed window, the throttle open.
rl6 0.01 $(($(date +%s) + 7200))
loop6

# AC-5: the CONFLICTING bot PR gets one update session.
ok "G01-AC-5: a bot's CONFLICTING spec PR gets an update session" waitf 8 runsis 101 1
ok "G01-AC-5: its prompt is /noodlebot:triage --update 101" grep -qF "update 101 run 1 /noodlebot:triage --update 101 |" "$GD/claude.log"
ok "G01-AC-5: it runs in worktrees/<name>/pr-101, on the PR's branch" grep -qF "| $wt6/pr-101 | spec/c1" "$GD/claude.log"
ok "G01-AC-5: its state is in state/<name>/pr/101/ (pid recorded)" test -s "$state/pr/101/session.pid"
ok "G01-AC-5: its start is start 1 of 2" waitf 3 pr_evis 101 'start 1 of 2' 1
ok "G01-AC-5: the running note shows the task as PR #101" within 5 "running: .*PR #101 \(pid [0-9]+\)"
if [ "$(s6runs 101)" = 1 ]; then
	# B: while it runs, nothing else starts: not the clashing PR's update, not a triage.
	echo '[{"number": 46}]' >"$GD/issues.json"
	wait_ticks 3
	ok "G01-AC-5: no second update starts while one runs" runsis 106 0
	ok "G01-AC-5: the update is not started a second time" runsis 101 1
	ok "G01-AC-5: no triage starts while an update runs" runsis t 0
	ok "G01-AC-5: a human's PR, a MERGEABLE one with no clash, an UNKNOWN one and a node/* PR get no update" sh -c "! grep -qE '^update 10[2345] ' '$GD/claude.log'"
	# C: it ends with rc 0.
	rm -f "$GD/hold.101"
	ok "G01-AC-6: an update ending with rc 0 is one status-log event" waitf 6 pr_evis 101 'rc 0' 1
	ok "G01-AC-6: and its worktree is removed" test ! -d "$wt6/pr-101"
	# The triage of #46 and the update of #106 want the one slot; whichever starts first holds the other off.
	ok "G01-AC-5: after it, the triage or the clashing PR's update takes the slot" waitf 8 sh -c "[ -s '$GD/runs.t' ] || [ -s '$GD/runs.106' ]"
	if [ -s "$GD/runs.t" ]; then first=t second=106; else first=106 second=t; fi
	wait_ticks 3
	if [ $first = t ]; then
		ok "G01-AC-5: no update starts while a triage runs" runsis 106 0
	else
		ok "G01-AC-5: no triage starts while an update runs" runsis t 0
	fi
	rm -f "$GD/hold.$first"
	ok "G01-AC-5: the other one starts when the first has ended" waitf 8 runsis $second 1
	rm -f "$GD/hold.$second"
	ok "G01-AC-5: a bot's MERGEABLE spec PR whose graph gives X02 of main to a node of another name gets an update" waitf 8 runsis 106 1
	ok "G01-AC-5: it runs in worktrees/<name>/pr-106 on spec/clash" grep -qF "| $wt6/pr-106 | spec/clash" "$GD/claude.log"
	ok "G01-AC-5: it is start 1 of 2, one event" waitf 3 pr_evis 106 'start 1 of 2' 1
	ok "G01-AC-6: its end (rc 0) is one status-log event" waitf 8 pr_evis 106 'rc 0' 1
	ok "G01-AC-6: its worktree is removed" waitf 3 test ! -d "$wt6/pr-106"
	# D: not started again until main or the PR's head moves.
	wait_ticks 3
	ok "G01-AC-6: after rc 0 neither PR is started again while main and the heads stay" sh -c "[ \"\$(cat '$GD/runs.101')\" = 1 ] && [ \"\$(cat '$GD/runs.106')\" = 1 ]"
	sed -i 's/^101 \(.*\) CONFLICTING$/101 \1 MERGEABLE/' "$GD/prs.tsv"
	mvref main
	ok "G01-AC-6: when main moves, a PR that still needs an update is started again" waitf 8 runsis 106 2
	wait_ticks 3
	ok "G01-AC-6: and one that no longer needs it is not (101 is MERGEABLE now)" runsis 101 1
	mvref spec/clash
	ok "G01-AC-6: when only the PR's head moves, it is started again" waitf 8 runsis 106 3
	wait_ticks 2
	ok "G01-AC-6: and each start is one event with its own end (3 starts, 3 ends)" sh -c "[ \"\$(grep -E 'PR #106([^0-9]|\$)' '$state/status.log' | grep -cE 'start [12] of 2')\" = 3 ] && [ \"\$(grep -E 'PR #106([^0-9]|\$)' '$state/status.log' | grep -cE 'rc 0')\" = 3 ]"
else
	fail "G01-AC-5/6: no update started, so the cases that need a running update were not run"
fi

touch "$HOME/STOP-up"
wait_until 5 g01_gone "$lp6"
for f in "$state"/pr/*/session.pid "$state"/issue/*/session.pid; do [ -e "$f" ] && kill -KILL -- "-$(cat "$f")" 2>/dev/null; done


loop_end
