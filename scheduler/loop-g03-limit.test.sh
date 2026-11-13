#!/bin/bash
# G03: a limit exit of a feedback session uses no start. Part of the end-to-end test of scheduler/loop.sh (fixture: testdata/lib/loop-g03.sh).
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"   # the runner runs *.test.sh with sh, except loop.test.sh
. "$(dirname "$0")/testdata/lib/loop-prelude.sh"
. "$src/testdata/lib/loop-g03.sh"

rl6 0.01 $(($(date +%s) + 7200))
loop6
ok "G03 setup: the first tick records the open PRs' feedback" g03_first
x=$state/node/X01
touch "$GD/limit.fbnode.11.1"
fbadd 11 conversation 121 'node point'
ok "G03-AC-5: a feedback session that ends by the usage limit is one status-log event, not counted" waitf 12 g03_endsis X01 1
ok "G03-AC-5: it says so (stopped by the usage limit, start not counted)" within 3 'stopped by the usage limit.*start not counted'
ok "G03-AC-5: the feedback is not lost: the session starts again, as start 1 of 2 again" waitf 12 runsis fbnode.11 2
ok "G03-AC-5: both starts are start 1 of 2, none is start 2 of 2" waitf 5 sh -c "[ \"\$(grep -E 'eedback' '$state/status.log' | grep -E '#11([^0-9]|\$)' | grep -c 'start 1 of 2')\" = 2 ] && [ \"\$(grep -cE 'eedback.*start 2 of 2' '$state/status.log')\" = 0 ]"
ok "G03-AC-5: the second session has the same FEEDBACK.md" cmp -s "$GD/fbseen.fbnode.11.1" "$GD/fbseen.fbnode.11.2"
ok "G03-AC-5: it ends with rc 0 and FEEDBACK.md moves into answered/" waitf 10 sh -c "[ ! -e '$x/FEEDBACK.md' ] && ls '$x'/answered/*-FEEDBACK.md >/dev/null 2>&1"
ok "G03-AC-5: no FAILED" test ! -e "$x/FAILED"
g03_stop
loop_end
