#!/bin/bash
# G01: a failing PR list starts nothing. Part of the end-to-end test of scheduler/loop.sh (fixture: testdata/lib/loop-g01.sh).
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"   # the runner runs *.test.sh with sh, except loop.test.sh
. "$(dirname "$0")/testdata/lib/loop-prelude.sh"
. "$src/testdata/lib/loop-g01.sh"

# The state the main run is in when it comes to this case: the throttle open (an allowed window), no holds, nothing running.
rm -f "$GD/hold.101" "$GD/hold.106" "$GD/hold.t"
sed -i 's/^101 \(.*\) CONFLICTING$/101 \1 MERGEABLE/; /^106 /d' "$GD/prs.tsv"
rl6 0.01 $(($(date +%s) + 7200))
loop6
wait_ticks 1   # the loop is running and its PR list works
# F: a failing PR list starts nothing.
touch "$GD/open.fail"
echo "108 spec/late app/noodlebot true CONFLICTING" >>"$GD/prs.tsv"
lines6=$(wc -l <"$state/status.log")
wait_ticks 3
ok "G01-AC-5: when the PR list fails, no update starts" runsis 108 0
ok "G01-AC-5: and the failure is logged" sh -c "tail -n +$((lines6 + 1)) '$state/status.log' | grep -qi 'pr list failed'"
rm -f "$GD/open.fail"
ok "G01-AC-5: once the list works, the PR gets its update" waitf 8 runsis 108 1
ok "G01-AC-5: a human's PR, a clean MERGEABLE one, an UNKNOWN one and a node/* PR never got an update" sh -c "! grep -qE '^update 10[2345] ' '$GD/claude.log'"
touch "$HOME/STOP-up"
wait_until 5 g01_gone "$lp6"
for f in "$state"/pr/*/session.pid "$state"/issue/*/session.pid; do [ -e "$f" ] && kill -KILL -- "-$(cat "$f")" 2>/dev/null; done


loop_end
