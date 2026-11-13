#!/bin/bash
# G03: no feedback session starts while the unit's own session runs or the unit has FAILED; held feedback starts once the hold ends, with every held item. Part of the end-to-end test of scheduler/loop.sh (fixture: testdata/lib/loop-g03.sh).
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"   # the runner runs *.test.sh with sh, except loop.test.sh
. "$(dirname "$0")/testdata/lib/loop-prelude.sh"
. "$src/testdata/lib/loop-g03.sh"

rl6 0.01 $(($(date +%s) + 7200))
loop6
ok "G03 setup: the first tick records the open PRs' feedback" g03_first
x=$state/node/X01
# a session of node X01 that the loop did not start by feedback: a recorded live process that looks like one
mkdir -p "$tmp/fakes" "$x"
printf '#!/bin/sh\nwhile [ -e "$GD/own" ]; do sleep 0.2; done\n' >"$tmp/fakes/run-session.sh"; chmod +x "$tmp/fakes/run-session.sh"
touch "$GD/own"
setsid "$tmp/fakes/run-session.sh" "$wt6/X01" "$x" "/noodlebot:node X01" </dev/null >/dev/null 2>&1 &
echo $! >"$x/session.pid"
ok "G03 setup: the loop sees the node's own session" within 6 "running: .*X01 \(pid $(cat "$x/session.pid")\)"
g03_hold fbnode.11
r0=$(cksum "$state/feedback/11" 2>/dev/null)
fbadd 11 conversation 121 'first point'
wait_ticks 3
fbadd 11 line 122 'second point'
wait_ticks 2
ok "G03-AC-4: no feedback session starts while the unit's own session runs" runsis fbnode.11 0
ok "G03-AC-4: nothing is handed over meanwhile: no FEEDBACK.md in the unit" test ! -e "$x/FEEDBACK.md"
ok "G03-AC-4: and the record stays as it is" test "$(cksum "$state/feedback/11" 2>/dev/null)" = "$r0"
rm -f "$GD/own"
ok "G03-AC-4: held feedback starts its session at the first tick after the hold ends" waitf 10 runsis fbnode.11 1
ok "G03-AC-4: its FEEDBACK.md holds every held item" sh -c "grep -qF '$(fburl 11 conversation 121)' '$GD/fbseen.fbnode.11.1' && grep -qF '$(fburl 11 line 122)' '$GD/fbseen.fbnode.11.1'"
g03_release fbnode.11
ok "G03 setup: that session ends" waitf 10 g03_idle "$x"
wait_ticks 2
ok "G03-AC-5: and starts nothing more" runsis fbnode.11 1

# FAILED
touch "$x/FAILED"
g03_hold fbnode.11
fbadd 11 conversation 131 'third point'
wait_ticks 3
fbadd 11 conversation 132 'fourth point'
wait_ticks 2
ok "G03-AC-4: no feedback session starts while the unit has FAILED" runsis fbnode.11 1
ok "G03-AC-4: nothing is handed over meanwhile" test ! -e "$x/FEEDBACK.md"
rm -f "$x/FAILED"
ok "G03-AC-4: held feedback starts its session at the first tick after FAILED is gone" waitf 10 runsis fbnode.11 2
ok "G03-AC-4: its FEEDBACK.md holds both held items" sh -c "grep -qF '$(fburl 11 conversation 131)' '$GD/fbseen.fbnode.11.2' && grep -qF '$(fburl 11 conversation 132)' '$GD/fbseen.fbnode.11.2'"
ok "G03-AC-4: and not the earlier, handed-over ones" g03_notseen fbnode.11.2 11 conversation 121

g03_stop
loop_end
