#!/bin/bash
# G03: feedback sessions with the start queue on (SCHED_RAMP=1): a node's takes the turn as a resumed unit, a spec PR's too has its turn. Part of the end-to-end test of scheduler/loop.sh (fixture: testdata/lib/loop-g03.sh).
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"   # the runner runs *.test.sh with sh, except loop.test.sh
. "$(dirname "$0")/testdata/lib/loop-prelude.sh"
. "$src/testdata/lib/loop-g03.sh"

rl6 0.01 $(($(date +%s) + 7200))
SCHED_RAMP=1 SCHED_START_GAP=1 loop6
ok "G03 setup: the first tick records the open PRs' feedback" g03_first
g03_hold fbnode.11; g03_hold fbspec.13
fbadd 11 conversation 121 'node point'
fbadd 13 conversation 321 'spec point'
ok "G03-AC-4: with the start queue on, the node's feedback session starts" waitf 15 runsis fbnode.11 1
ok "G03-AC-4: it takes the turn as a resumed unit" waitf 3 sh -c "grep -E 'eedback' '$state/status.log' | grep -E '#11([^0-9]|\$)' | grep -q 'turn: resumed'"
ok "G03-AC-4: with the start queue on, the spec PR's feedback session starts" waitf 15 runsis fbspec.13 1
ok "G03-AC-3: each is one session and one start-1 event" sh -c "[ \"\$(grep -E 'eedback' '$state/status.log' | grep -E '#11([^0-9]|\$)' | grep -c 'start 1 of 2')\" = 1 ] && [ \"\$(grep -E 'eedback' '$state/status.log' | grep -E '#13([^0-9]|\$)' | grep -c 'start 1 of 2')\" = 1 ]"
g03_stop
loop_end
