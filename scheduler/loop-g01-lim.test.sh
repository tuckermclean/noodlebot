#!/bin/bash
# G01: a limit exit uses no start (PR 107). Part of the end-to-end test of scheduler/loop.sh (fixture: testdata/lib/loop-g01.sh).
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"   # the runner runs *.test.sh with sh, except loop.test.sh
. "$(dirname "$0")/testdata/lib/loop-prelude.sh"
. "$src/testdata/lib/loop-g01.sh"

# The state the main run is in when it comes to this case: the throttle open (an allowed window), no holds, nothing running.
rm -f "$GD/hold.101" "$GD/hold.106" "$GD/hold.t"
sed -i 's/^101 \(.*\) CONFLICTING$/101 \1 MERGEABLE/; /^106 /d' "$GD/prs.tsv"
rl6 0.01 $(($(date +%s) + 7200))
loop6
# E: a limit exit uses no start; the second end without rc 0 writes FAILED.
echo "107 spec/lim app/noodlebot true CONFLICTING" >>"$GD/prs.tsv"
ok "G01-AC-6: a limit exit uses no start: two starts are both start 1 of 2" waitf 12 pr_evis 107 'start 1 of 2' 2
ok "G01-AC-6: the second end without rc 0 writes FAILED" waitf 12 test -e "$state/pr/107/FAILED"
ok "G01-AC-6: the third start is start 2 of 2" pr_evis 107 'start 2 of 2' 1
ok "G01-AC-6: each of the three ends is one status-log event" waitf 5 pr_evis 107 'rc 1' 3
wait_ticks 3
ok "G01-AC-6: with FAILED there, the PR gets no update" runsis 107 3
rm -f "$state/pr/107/FAILED"
ok "G01-AC-6: after FAILED is deleted it is started again" waitf 8 runsis 107 4
ok "G01-AC-6: and that end (rc 0) is one more event" waitf 6 pr_evis 107 'rc 0' 1

# the same check as the label in loop-g01-list.test.sh, over this part's claude.log: prints only on failure (the PASS label stays once, in that part)
grep -qE '^update 10[2345] ' "$GD/claude.log" && fail "G01-AC-5: a human's PR, a clean MERGEABLE one, an UNKNOWN one and a node/* PR never got an update (in $(basename "$0"))"
touch "$HOME/STOP-up"
wait_until 5 g01_gone "$lp6"
for f in "$state"/pr/*/session.pid "$state"/issue/*/session.pid; do [ -e "$f" ] && kill -KILL -- "-$(cat "$f")" 2>/dev/null; done


loop_end
