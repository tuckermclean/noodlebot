#!/bin/bash
# G01: while the throttle holds, no update starts; once it opens one does. Part of the end-to-end test of scheduler/loop.sh (fixture: testdata/lib/loop-g01.sh).
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"   # the runner runs *.test.sh with sh, except loop.test.sh
. "$(dirname "$0")/testdata/lib/loop-prelude.sh"
. "$src/testdata/lib/loop-g01.sh"

# AC-5: while the throttle holds, no update starts.
rl6 0.99 $(($(date +%s) + 3600))
loop6
ok "G01-AC-5 setup: the throttle engages" within 8 "throttle engaged"
wait_ticks 3
ok "G01-AC-5: while the throttle holds, a bot's CONFLICTING spec PR gets no update" runsis 101 0
ok "G01-AC-5: while the throttle holds, a clashing one gets none either" runsis 106 0
rl6 0.01 $(($(date +%s) + 7200))
ok "G01-AC-5 setup: the throttle is released" within 6 "throttle released"
touch "$HOME/STOP-up"
wait_until 5 g01_gone "$lp6"
for f in "$state"/pr/*/session.pid "$state"/issue/*/session.pid; do [ -e "$f" ] && kill -KILL -- "-$(cat "$f")" 2>/dev/null; done

loop_end
