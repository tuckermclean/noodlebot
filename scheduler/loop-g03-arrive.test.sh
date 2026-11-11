#!/bin/bash
# G03: feedback that arrives while a feedback session runs starts one more session after it ends, with only the new items. Part of the end-to-end test of scheduler/loop.sh (fixture: testdata/lib/loop-g03.sh).
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"   # the runner runs *.test.sh with sh, except loop.test.sh
. "$(dirname "$0")/testdata/lib/loop-prelude.sh"
. "$src/testdata/lib/loop-g03.sh"

rl6 0.01 $(($(date +%s) + 7200))
loop6
ok "G03 setup: the first tick records the open PRs' feedback" g03_first
x=$state/node/X01 p=$state/pr/13
g03_hold fbnode.11; g03_hold fbspec.13
fbadd 11 conversation 121 'first node point'
fbadd 13 conversation 321 'first spec point'
ok "G03 setup: both feedback sessions run" waitf 12 sh -c "[ \"\$(cat '$GD/runs.fbnode.11' 2>/dev/null 2>/dev/null)\" = 1 ] && [ \"\$(cat '$GD/runs.fbspec.13' 2>/dev/null 2>/dev/null)\" = 1 ]"
fbadd 11 line 122 'second node point'
fbadd 11 conversation 123 'third node point'
fbadd 13 conversation 322 'second spec point'
mvref node/X01-first   # the PR's branch moves meanwhile
wait_ticks 3
ok "G03-AC-4: no second node session starts while the first runs" runsis fbnode.11 1
ok "G03-AC-4: nor a second spec-PR session" runsis fbspec.13 1
ok "G03-AC-4: the running session's FEEDBACK.md is not changed under it" sh -c "! grep -qF '$(fburl 11 line 122)' '$x/FEEDBACK.md' && ! grep -qF '$(fburl 13 conversation 322)' '$p/FEEDBACK.md'"
g03_release fbnode.11; g03_release fbspec.13
ok "G03-AC-4: when the node session ends, one more starts" waitf 10 runsis fbnode.11 2
ok "G03-AC-4: its FEEDBACK.md holds only the new items" sh -c "grep -qF '$(fburl 11 line 122)' '$GD/fbseen.fbnode.11.2' && grep -qF '$(fburl 11 conversation 123)' '$GD/fbseen.fbnode.11.2' && ! grep -qF '$(fburl 11 conversation 121)' '$GD/fbseen.fbnode.11.2' && [ \"\$(grep -c '^kind: ' '$GD/fbseen.fbnode.11.2')\" = 2 ]"
ok "G03-AC-3: the worktree is brought to origin/<branch> (its new head)" grep -qF "fbnode 11 run 2 /noodlebot:node --feedback 11 | $wt6/X01 | node/X01-first | $(g03_tip node/X01-first)" "$GD/claude.log"
ok "G03-AC-4: when the spec session ends, one more starts" waitf 10 runsis fbspec.13 2
ok "G03-AC-4: its FEEDBACK.md holds only the new item" sh -c "g03_seen() { grep -qF \"\$1\" '$GD/fbseen.fbspec.13.2'; }; g03_seen '$(fburl 13 conversation 322)' && ! g03_seen '$(fburl 13 conversation 321)'"
wait_ticks 3
ok "G03-AC-4: and no more: each PR got exactly two sessions" sh -c "[ \"\$(cat '$GD/runs.fbnode.11' 2>/dev/null)\" = 2 ] && [ \"\$(cat '$GD/runs.fbspec.13' 2>/dev/null)\" = 2 ]"
ok "G03-AC-4: each start is one start-1 event (2 per PR)" sh -c "[ \"\$(grep -E 'eedback' '$state/status.log' | grep -E '#11([^0-9]|\$)' | grep -c 'start 1 of 2')\" = 2 ] && [ \"\$(grep -E 'eedback' '$state/status.log' | grep -E '#13([^0-9]|\$)' | grep -c 'start 1 of 2')\" = 2 ]"
g03_stop
loop_end
