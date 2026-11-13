#!/bin/bash
# G03: feedback sessions count toward SCHED_MAX. Part of the end-to-end test of scheduler/loop.sh (fixture: testdata/lib/loop-g03.sh).
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"   # the runner runs *.test.sh with sh, except loop.test.sh
. "$(dirname "$0")/testdata/lib/loop-prelude.sh"
. "$src/testdata/lib/loop-g03.sh"

rl6 0.01 $(($(date +%s) + 7200))
SCHED_MAX=1 loop6
ok "G03 setup: the first tick records the open PRs' feedback" g03_first
g03_hold fbnode.11; g03_hold fbnode.12
fbadd 11 conversation 121 'first node point'
ok "G03-AC-4: with SCHED_MAX=1 the first feedback session starts" waitf 10 runsis fbnode.11 1
fbadd 12 conversation 221 'second node point'
wait_ticks 3
ok "G03-AC-4: a second feedback session does not start while the first counts against SCHED_MAX" runsis fbnode.12 0
ok "G03-AC-4: nothing is handed over for it meanwhile" test ! -e "$state/node/X02/FEEDBACK.md"
fbadd 13 conversation 321 'spec point'
wait_ticks 2
ok "G03-AC-4: nor a spec-PR feedback session" runsis fbspec.13 0
g03_release fbnode.11
ok "G03-AC-4: the held node feedback starts when the first session has ended" waitf 10 runsis fbnode.12 1
ok "G03-AC-4: with its item" g03_seen fbnode.12.1 12 conversation 221
g03_release fbnode.12
ok "G03-AC-4: the spec PR's feedback starts after that" waitf 10 runsis fbspec.13 1
g03_stop
loop_end
