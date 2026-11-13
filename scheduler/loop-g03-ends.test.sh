#!/bin/bash
# G03: a feedback session that ends with rc 0 and no QUESTION.md moves FEEDBACK.md into answered/ and starts nothing more until new feedback arrives (node and spec PR); each end is one status-log event. Part of the end-to-end test of scheduler/loop.sh (fixture: testdata/lib/loop-g03.sh).
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"   # the runner runs *.test.sh with sh, except loop.test.sh
. "$(dirname "$0")/testdata/lib/loop-prelude.sh"
. "$src/testdata/lib/loop-g03.sh"

rl6 0.01 $(($(date +%s) + 7200))
loop6
ok "G03 setup: the first tick records the open PRs' feedback" g03_first
x=$state/node/X01 p=$state/pr/13
g03_hold fbnode.11; g03_hold fbspec.13
fbadd 11 conversation 121 'node point'
fbadd 13 conversation 321 'spec point'
ok "G03 setup: both sessions run" waitf 12 sh -c "[ \"\$(cat '$GD/runs.fbnode.11' 2>/dev/null 2>/dev/null)\" = 1 ] && [ \"\$(cat '$GD/runs.fbspec.13' 2>/dev/null 2>/dev/null)\" = 1 ]"
ok "G03-AC-5 setup: the node's FEEDBACK.md is in its state folder while it runs" test -s "$x/FEEDBACK.md"
en=$(g03_ends X01) es=$(g03_ends 'PR #13([^0-9]|$)')
g03_release fbnode.11
ok "G03-AC-5: a node session that ends with rc 0 and no QUESTION.md: FEEDBACK.md leaves the unit" waitf 10 test ! -e "$x/FEEDBACK.md"
ok "G03-AC-5: it is in answered/ as <ts>-FEEDBACK.md, with its item" sh -c "[ \$(ls '$x'/answered/*-FEEDBACK.md | wc -l) = 1 ] && grep -qF '$(fburl 11 conversation 121)' '$x'/answered/*-FEEDBACK.md"
ok "G03-AC-5: the end is one status-log event" waitf 5 g03_endsis X01 $((en + 1))
g03_release fbspec.13
ok "G03-AC-5: a spec-PR session that ends with rc 0 and no QUESTION.md: FEEDBACK.md leaves pr/13/" waitf 10 test ! -e "$p/FEEDBACK.md"
ok "G03-AC-5: it is in pr/13/answered/ as <ts>-FEEDBACK.md, with its item" sh -c "[ \$(ls '$p'/answered/*-FEEDBACK.md | wc -l) = 1 ] && grep -qF '$(fburl 13 conversation 321)' '$p'/answered/*-FEEDBACK.md"
ok "G03-AC-5: that end is one status-log event" waitf 5 g03_endsis 'PR #13([^0-9]|$)' $((es + 1))
wait_ticks 3
ok "G03-AC-5: nothing more starts until new feedback arrives (node)" runsis fbnode.11 1
ok "G03-AC-5: nor for the spec PR" runsis fbspec.13 1
ok "G03-AC-5: the ends did not write FAILED" sh -c "[ ! -e '$x/FAILED' ] && [ ! -e '$p/FAILED' ]"
fbadd 11 conversation 131 'new node point'
fbadd 13 conversation 331 'new spec point'
ok "G03-AC-5: new feedback starts the node again, with only the new item" waitf 10 sh -c "[ \"\$(cat '$GD/runs.fbnode.11' 2>/dev/null)\" = 2 ] && [ -f '$GD/fbseen.fbnode.11.2' ] && grep -qF '$(fburl 11 conversation 131)' '$GD/fbseen.fbnode.11.2' && ! grep -qF '$(fburl 11 conversation 121)' '$GD/fbseen.fbnode.11.2'"
ok "G03-AC-5: and the spec PR, with only the new item" waitf 10 sh -c "[ \"\$(cat '$GD/runs.fbspec.13' 2>/dev/null)\" = 2 ] && [ -f '$GD/fbseen.fbspec.13.2' ] && grep -qF '$(fburl 13 conversation 331)' '$GD/fbseen.fbspec.13.2' && ! grep -qF '$(fburl 13 conversation 321)' '$GD/fbseen.fbspec.13.2'"
g03_stop
loop_end
