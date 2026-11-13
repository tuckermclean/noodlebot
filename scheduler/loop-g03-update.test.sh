#!/bin/bash
# G03: no feedback session starts while an update session of the same PR runs. Part of the end-to-end test of scheduler/loop.sh (fixture: testdata/lib/loop-g03.sh).
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"   # the runner runs *.test.sh with sh, except loop.test.sh
. "$(dirname "$0")/testdata/lib/loop-prelude.sh"
. "$src/testdata/lib/loop-g03.sh"

rl6 0.01 $(($(date +%s) + 7200))
loop6
ok "G03 setup: the first tick records the open PRs' feedback" g03_first
p=$state/pr/13
# the bot's spec PR 13 now conflicts with main: an update session of the PR starts
g03_hold update.13
sed -i 's/^13 \(.*\) MERGEABLE$/13 \1 CONFLICTING/' "$GD/prs.tsv"
ok "G03 setup: the update of PR 13 starts and runs" waitf 10 runsis update.13 1
g03_hold fbspec.13
fbadd 13 conversation 121 'first point'
wait_ticks 2
fbadd 13 conversation 122 'second point'
wait_ticks 2
ok "G03-AC-4: no feedback session starts while an update session of the same PR runs" runsis fbspec.13 0
ok "G03-AC-4: nothing is handed over meanwhile" test ! -e "$p/FEEDBACK.md"
g03_release update.13
ok "G03-AC-4: held feedback starts its session at the first tick after the update ended" waitf 10 runsis fbspec.13 1
ok "G03-AC-4: with every held item in FEEDBACK.md" sh -c "grep -qF '$(fburl 13 conversation 121)' '$GD/fbseen.fbspec.13.1' && grep -qF '$(fburl 13 conversation 122)' '$GD/fbseen.fbspec.13.1'"
ok "G03-AC-4: and the update is not started again" runsis update.13 1
g03_stop
loop_end
