#!/bin/bash
# G03: spec-PR feedback shares the triage's slot: none while a triage or another PR's update runs. Part of the end-to-end test of scheduler/loop.sh (fixture: testdata/lib/loop-g03.sh).
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"   # the runner runs *.test.sh with sh, except loop.test.sh
. "$(dirname "$0")/testdata/lib/loop-prelude.sh"
. "$src/testdata/lib/loop-g03.sh"

rl6 0.01 $(($(date +%s) + 7200))
loop6
ok "G03 setup: the first tick records the open PRs' feedback" g03_first
p=$state/pr/13
# a triage of issue 46 is running
g03_hold triage.t
echo '[{"number": 46}]' >"$GD/issues.json"
ok "G03 setup: the triage of issue 46 starts and runs" waitf 10 runsis triage.t 1
echo '[]' >"$GD/issues.json"
g03_hold fbspec.13
fbadd 13 conversation 121 'first point'
wait_ticks 2
fbadd 13 conversation 122 'second point'
wait_ticks 2
ok "G03-AC-3: no spec-PR feedback session starts while a triage runs" runsis fbspec.13 0
ok "G03-AC-3: nothing is handed over meanwhile" test ! -e "$p/FEEDBACK.md"
g03_release triage.t
ok "G03-AC-3: it starts once the triage has ended" waitf 10 runsis fbspec.13 1
ok "G03-AC-3: with both held items" sh -c "grep -qF '$(fburl 13 conversation 121)' '$GD/fbseen.fbspec.13.1' && grep -qF '$(fburl 13 conversation 122)' '$GD/fbseen.fbspec.13.1'"
g03_release fbspec.13
ok "G03 setup: that session ends" waitf 10 g03_idle "$p"

# the update session of another spec PR (15: its graph clashes with main's) is running
g03_hold update.15
echo "15 spec/clash app/noodlebot true MERGEABLE" >>"$GD/prs.tsv"
ok "G03 setup: the update of PR 15 starts and runs" waitf 10 runsis update.15 1
g03_hold fbspec.13
fbadd 13 conversation 131 'third point'
wait_ticks 2
fbadd 13 line 132 'fourth point'
wait_ticks 2
ok "G03-AC-3: no spec-PR feedback session starts while another PR's update runs" runsis fbspec.13 1
g03_release update.15
ok "G03-AC-3: it starts once that update has ended" waitf 10 runsis fbspec.13 2
ok "G03-AC-3: with both items that arrived meanwhile, and none of the handed-over ones" sh -c "grep -qF '$(fburl 13 conversation 131)' '$GD/fbseen.fbspec.13.2' && grep -qF '$(fburl 13 line 132)' '$GD/fbseen.fbspec.13.2' && ! grep -qF '$(fburl 13 conversation 121)' '$GD/fbseen.fbspec.13.2'"
g03_stop
loop_end
