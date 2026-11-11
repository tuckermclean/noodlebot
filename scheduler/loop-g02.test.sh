#!/bin/bash
# G02: the throttle, one update at a time, its spec-PR neighbour, N05's running session. Part of the end-to-end test of scheduler/loop.sh (fixture: testdata/lib/loop-g02.sh).
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"   # the runner runs *.test.sh with sh, except loop.test.sh
. "$(dirname "$0")/testdata/lib/loop-prelude.sh"
. "$src/testdata/lib/loop-g02.sh"

# node N05's session runs (the fake one), before the loop starts
mkdir -p "$state/node/N05"
sh "$G02/fake/run-session.sh" x N05 </dev/null >/dev/null 2>&1 &
g02_np=$!; pids+=("$g02_np"); echo "$g02_np" >"$state/node/N05/session.pid"

# G02-AC-1: while the throttle holds, no node-PR update starts.
g02_rl 0.99 $(($(date +%s) + 3600))
g02_loop 0
ok "G02-AC-1 setup: the throttle engages" within 8 "throttle engaged"
wait_ticks 3
ok "G02-AC-1: while the throttle holds, a bot's CONFLICTING node PR gets no update" g02_runsis 201 0
g02_rl 0.01 $(($(date +%s) + 7200))
ok "G02-AC-1 setup: the throttle is released" within 6 "throttle released"

ok "G02-AC-1: the update prompt is rendered from scheduler/unattended-node-update.md (the file exists and has @N@)" sh -c "[ -s '$src/unattended-node-update.md' ] && grep -q '@N@' '$src/unattended-node-update.md'"
ok "G02-AC-1: a bot's CONFLICTING node PR gets an update session" waitf 8 g02_runsis 201 1
ok "G02-AC-1 setup: the update's prompt is logged (review3 #10: the next check must not race the log)" waitf 5 grep -qF "nupd 201 run 1 /noodlebot:node --update 201 |" "$G02_GD/claude.log"
ok "G02-AC-1: its prompt is /noodlebot:node --update 201" grep -qF "nupd 201 run 1 /noodlebot:node --update 201 |" "$G02_GD/claude.log"
ok "G02-AC-1: it runs in worktrees/<name>/pr-201, on the PR's branch" grep -qF "| $g02_wt/pr-201 | node/N01-alpha" "$G02_GD/claude.log"
ok "G02-AC-1: pr/201/node holds the PR's node ID (N01)" test "$(cat "$state/pr/201/node" 2>/dev/null)" = N01
ok "G02-AC-1: its state is in state/<name>/pr/201/ (pid recorded)" test -s "$state/pr/201/session.pid"
ok "G02-AC-1: pr/201/unattended.md is rendered from the template" grep -qF "G02-TEMPLATE for PR #201 in $g02_wt/pr-201 state $state/pr/201" "$state/pr/201/unattended.md"
ok "G02-AC-1: its start is start 1 of 2, one status-log event" waitf 3 g02_evis 201 'start 1 of 2' 1
if [ "$(g02_runs 201)" = 1 ]; then
	wait_ticks 3
	ok "G02-AC-1: a human's node PR, a MERGEABLE one and an UNKNOWN one get no update" sh -c "! grep -qE '^nupd 20[234] ' '$G02_GD/claude.log'"
	ok "G02-AC-1: no update starts while PR 205's node (N05) has a running session" g02_runsis 205 0
	ok "G02-AC-1: the update is not started a second time while it runs" g02_runsis 201 1
	ok "G02-AC-1: the node's own session (N01) does not start while its update runs" sh -c "! grep -qE '^node N01 ' '$G02_GD/claude.log'"
	# it does not take the triage's slot
	echo '[{"number": 46}]' >"$G02_GD/issues.json"
	ok "G02-AC-1: a node-PR update does not take the triage's slot: a triage runs alongside it" waitf 8 g02_runsis t 1
	ok "G02-AC-1: and the update still runs (one start)" g02_runsis 201 1
	echo '[]' >"$G02_GD/issues.json"; rm -f "$G02_GD/hold.t"
	echo "220 spec/s1 app/noodlebot true CONFLICTING" >>"$G02_GD/prs.tsv"
	ok "G02-AC-1: nor does it keep a spec-PR update from starting alongside it" waitf 8 g02_runsis 220 1
	rm -f "$G02_GD/hold.220"
	waitf 8 g02_evis 220 'rc 0' 1
	g02_prs 220 MERGEABLE
else
	fail "G02-AC-1/2: no node-PR update started, so the cases that need a running update were not run"
fi
g02_stop

loop_end
