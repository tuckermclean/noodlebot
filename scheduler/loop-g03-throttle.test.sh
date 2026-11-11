#!/bin/bash
# G03: while the throttle holds no feedback session starts (node and spec PR); when it opens, they start with every held item. Part of the end-to-end test of scheduler/loop.sh (fixture: testdata/lib/loop-g03.sh).
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"   # the runner runs *.test.sh with sh, except loop.test.sh
. "$(dirname "$0")/testdata/lib/loop-prelude.sh"
. "$src/testdata/lib/loop-g03.sh"

rl6 0.01 $(($(date +%s) + 7200))
loop6
ok "G03 setup: the first tick records the open PRs' feedback" g03_first
rl6 0.99 $(($(date +%s) + 3600))
# usage.py keeps, per window, the reading with the latest reset: this one must reset later than the first
rl6 0.99 $(($(date +%s) + 7300))
ok "G03 setup: the throttle engages" within 8 "throttle engaged"
fbadd 11 conversation 121 'first point'
fbadd 13 conversation 321 'spec point'
wait_ticks 2
fbadd 11 line 122 'second point'
wait_ticks 2
ok "G03-AC-4: while the throttle holds, no node feedback session starts" runsis fbnode.11 0
ok "G03-AC-4: nor a spec-PR feedback session" runsis fbspec.13 0
ok "G03-AC-4: nothing is handed over meanwhile" sh -c "[ ! -e '$state/node/X01/FEEDBACK.md' ] && [ ! -e '$state/pr/13/FEEDBACK.md' ]"
rl6 0.01 $(($(date +%s) + 7200))
rl6 0.01 $(($(date +%s) + 7400))
ok "G03 setup: the throttle is released" within 6 "throttle released"
ok "G03-AC-4: the node's feedback starts its session" waitf 10 runsis fbnode.11 1
ok "G03-AC-4: with every held item" sh -c "grep -qF '$(fburl 11 conversation 121)' '$GD/fbseen.fbnode.11.1' && grep -qF '$(fburl 11 line 122)' '$GD/fbseen.fbnode.11.1'"
ok "G03-AC-4: the spec PR's feedback starts its session" waitf 10 runsis fbspec.13 1
ok "G03-AC-4: with its item" g03_seen fbspec.13.1 13 conversation 321
g03_stop
loop_end
