#!/bin/bash
# G03-AC-3: a node whose PR was made by its 2nd start still gets its owner's feedback handed over and run, as start 1 of 2. Part of the end-to-end test of scheduler/loop.sh (fixture: testdata/lib/loop-g03.sh).
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"   # the runner runs *.test.sh with sh, except loop.test.sh
. "$(dirname "$0")/testdata/lib/loop-prelude.sh"
. "$src/testdata/lib/loop-g03.sh"

rl6 0.01 $(($(date +%s) + 7200))
loop6
ok "G03 setup: the first tick records the open PRs' feedback" g03_first
x=$state/node/X01
echo 2 >"$x/starts"
fbadd 11 conversation 121 'a point on the PR of the 2nd start'
ok "G03-AC-3: feedback on a PR made by the node's 2nd start starts one feedback session" waitf 5 runsis fbnode.11 1
ok "G03-AC-3: its FEEDBACK.md holds the comment" g03_seen fbnode.11.1 11 conversation 121
ok "G03-AC-3: the status log names it start 1 of 2" waitf 3 g03_startedis 11 1 1
wait_ticks 3
ok "G03-AC-3: the loop never says the node has used 2 starts" test -z "$(grep -E 'X01.*used 2 starts' "$state/status.log" 2>/dev/null)"

g03_stop
loop_end
