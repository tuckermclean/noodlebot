#!/bin/bash
# G03: any other end of a feedback session uses one of 2 starts, and the second writes FAILED; each end is one status-log event. Part of the end-to-end test of scheduler/loop.sh (fixture: testdata/lib/loop-g03.sh).
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"   # the runner runs *.test.sh with sh, except loop.test.sh
. "$(dirname "$0")/testdata/lib/loop-prelude.sh"
. "$src/testdata/lib/loop-g03.sh"

rl6 0.01 $(($(date +%s) + 7200))
loop6
ok "G03 setup: the first tick records the open PRs' feedback" g03_first
x=$state/node/X01
echo 1 >"$GD/rc.fbnode.11.1"; echo 1 >"$GD/rc.fbnode.11.2"
fbadd 11 conversation 121 'node point'
ok "G03-AC-5: a first end with rc 1 is one status-log event" waitf 12 g03_endsis X01 1
ok "G03-AC-5: it uses one start: the session starts again as start 2 of 2" waitf 12 g03_startedis 11 2 1
ok "G03-AC-5: the second end with rc 1 writes FAILED" waitf 12 test -e "$x/FAILED"
ok "G03-AC-5: and is one more status-log event (2 in all)" waitf 5 g03_endsis X01 2
ok "G03-AC-5: the second session had the same FEEDBACK.md" cmp -s "$GD/fbseen.fbnode.11.1" "$GD/fbseen.fbnode.11.2"
wait_ticks 3
ok "G03-AC-5: with FAILED there, no third session starts" runsis fbnode.11 2
ok "G03-AC-5: the FEEDBACK.md is kept (not answered)" test -s "$x/FEEDBACK.md"
g03_stop
loop_end
