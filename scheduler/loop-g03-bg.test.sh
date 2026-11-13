#!/bin/bash
# G03: feedback.py runs in the background, off the tick's critical path: a slow gh api does not slow the ticks (one run at a time), feedback still starts, a failed run hands nothing over, and a stopped loop leaves no feedback.py. Part of the end-to-end test of scheduler/loop.sh (fixture: testdata/lib/loop-g03.sh).
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"   # the runner runs *.test.sh with sh, except loop.test.sh
. "$(dirname "$0")/testdata/lib/loop-prelude.sh"
. "$src/testdata/lib/loop-g03.sh"

# A slow api: while $GD/fb.slow exists each `gh api` call of the fake gh sleeps 0.3 s, and 3.7 s more while $GD/fb.slow1 also exists (4 s a call); a run makes 3 calls per open bot PR (9) on 4 threads: about 1 s, about 12 s with fb.slow1 (U-1 only).
# The other behaviour of the fake is the fixture's ($GD/fb.fail makes the calls fail).
sed -i '/^\t*echo "\$3" >>"\$GD\/fbcalls"/a \	[ -e "$GD/fb.slow" ] \&\& sleep 0.3' "$tmp/bin6/gh"
sed -i '/^\t*echo "\$3" >>"\$GD\/fbcalls"/a \	[ -e "$GD/fb.slow1" ] \&\& sleep 3.7' "$tmp/bin6/gh"
# fbprocs: the listing runs of feedback.py (not its `mark` call) of the loop on this state dir.
fbprocs() { ps -eo args= | grep -E "^python3 -I [^ ]*feedback\\.py .*--state $state( |\$)" | grep -vcE ' mark( |$)'; }
fbbusy() { [ "$(fbprocs)" -ge 1 ]; }
fbnone() { [ "$(fbprocs)" = 0 ]; }
# the sampler: each 0.05 s it looks at the running listing runs and notes more than one in $tmp/fbconc
( while :; do [ "$(fbprocs)" -gt 1 ] && echo "$(fbprocs) at $(date +%s)" >>"$tmp/fbconc"; sleep 0.05; done ) &
pids+=("$!")
# ticks_in <seconds> <n>: the loop's heartbeat (one epoch second per tick) changed n times within that time.
ticks_in() {
	local end=$(($(date +%s%N) + $1 * 1000000000)) c=0 last h
	last=$(cat "$state/heartbeat" 2>/dev/null)
	while [ "$(date +%s%N)" -lt "$end" ]; do
		h=$(cat "$state/heartbeat" 2>/dev/null)
		[ "$h" != "$last" ] && { c=$((c + 1)); last=$h; }
		[ "$c" -ge "$2" ] && return 0
		sleep 0.1
	done
	return 1
}
g03b_failed() { grep -c 'feedback.py failed' "$state/status.log"; }
g03b_failedis() { [ "$(g03b_failed)" = "$1" ]; }
g03b_calls() { wc -l <"$GD/fbcalls" 2>/dev/null || echo 0; }
g03b_callsge() { [ "$(g03b_calls)" -ge "$1" ]; }
g03b_rec() { ls -a "$state/feedback" 2>/dev/null | grep -E '^12(\.|$)' | while read -r f; do echo "$f"; cat "$state/feedback/$f"; done | cksum; }
g03b_seen() { grep -qF "$(fburl "$1" "$2" "$3")" "$GD/fbseen.$4" 2>/dev/null; }

rl6 0.01 $(($(date +%s) + 7200))
loop6
ok "G03 setup: the first tick records the open PRs' feedback" g03_first
x=$state/node/X01 y=$state/node/X02

# U-1: a slow api does not slow the ticks, and one run of feedback.py is in flight at a time.
touch "$GD/fb.slow"
touch "$GD/fb.slow1"
ok "U-1 setup: a run of feedback.py is in flight under the slow api" waitf 10 fbbusy
ok "U-1: the ticks keep their pace while the run is in flight: 4 ticks within 8 s (a run takes about 12 s)" ticks_in 8 4
ok "U-1: and a feedback.py is still running (the loop did not wait for it)" fbbusy
rm -f "$GD/fb.slow1"

# U-2: feedback added while the api is slow still starts its session, with the item.
fbadd 11 conversation 121 'node point'
ok "U-2: the feedback session of node X01 starts from the first whole run that saw the item (slow api)" waitf 20 runsis fbnode.11 1
ok "U-2: the session got the item" g03b_seen 11 conversation 121 fbnode.11.1
ok "U-2 setup: the session ended" waitf 10 g03_idle "$x"
ok "U-1: the listing runs never overlapped (never more than one feedback.py of the loop at a time)" test ! -s "$tmp/fbconc"

# U-3: a failed run hands nothing over.
touch "$GD/fb.fail"; rm -f "$GD/fb.slow"
ok "U-3 setup: a failed run is one status-log line" waitf 20 g03b_failedis 1
fbadd 12 conversation 231 'node point (while the api fails)'
rec0=$(g03b_rec); c0=$(g03b_calls)
ok "U-3 setup: more runs than one fail" waitf 20 g03b_callsge $((c0 + 3))
wait_ticks 3
ok "U-3: a failed run hands nothing over: no session of node X02 starts" runsis fbnode.12 0
ok "U-3: no FEEDBACK.md appears in the unit's folder" test ! -e "$y/FEEDBACK.md"
ok "U-3: state/feedback/12 is unchanged" test "$(g03b_rec)" = "$rec0"
ok "U-3: failing runs are one status-log line (said once per streak, not once per tick)" g03b_failedis 1
rm -f "$GD/fb.fail"
ok "U-3: after the failure is cleared the feedback is handed over" waitf 20 runsis fbnode.12 1
ok "U-3: with the item" g03b_seen 12 conversation 231 fbnode.12.1

# U-4: no feedback.py is left behind when the loop is stopped (a signal, then ~/STOP).
ok "U-4 setup: the session of X02 ended" waitf 10 g03_idle "$y"
touch "$GD/fb.slow"
touch "$GD/fb.slow1"   # 12 s a run: an orphaned run is still alive at the fbnone checks
ok "U-4 setup: a run is in flight" waitf 10 fbbusy
kill "$lp6"
ok "U-4 setup: the loop is gone after the signal" waitf 20 g01_gone "$lp6"
ok "U-4: no feedback.py of the loop is left running after a signal" waitf 2 fbnone
loop6
ok "U-4 setup: the restarted loop has a run in flight" waitf 10 fbbusy
touch "$HOME/STOP-up"
ok "U-4 setup: the loop is gone after ~/STOP" waitf 20 g01_gone "$lp6"
ok "U-4: no feedback.py of the loop is left running after ~/STOP" waitf 2 fbnone
rm -f "$GD/fb.slow1"
rm -f "$HOME/STOP-up"
ok "U-1: the listing runs never overlapped over the whole file" test ! -s "$tmp/fbconc"
g03_stop
loop_end
