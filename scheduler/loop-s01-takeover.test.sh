#!/bin/bash
# S01-AC-1: a session taken over after a restart is stopped when its PR merged while the loop was down. Part of the end-to-end test of scheduler/loop.sh.
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"   # the runner runs *.test.sh with sh, except loop.test.sh
. "$(dirname "$0")/testdata/lib/loop-prelude.sh"
. "$src/testdata/lib/loop-fakes.sh"
. "$src/testdata/lib/loop-s01.sh"
mkdir -p "$state/node/B01" "$state/node/B02"
touch "$state/node/B01/FAILED" "$state/node/B02/FAILED"   # B01 and B02 are the subject of loop-s01.test.sh and loop-s01-closed.test.sh
# the state loop-s01.test.sh has reached by here: B03, B04, B05 and B06 run; B03 and B04 have closed PRs (B04 also an open one)
loop4; loop1s=$lp4
waitf 20 sh -c "[ \$(ls '$S01'/child.B0[3-6].1 2>/dev/null | wc -l) = 4 ]"
p3=$(pg B03) p4=$(pg B04) p5=$(pg B05) p6=$(pg B06)
wait_until 5 s01_started 4
now=$(date +%s)
echo node/B04-n4 >"$S01/open.txt"   # open.txt first, as in loop-s01.test.sh
wait_polls "$S01/polls" "$(polls "$S01/polls")" 2
printf '13 node/B03-n3 %s 0\n14 node/B04-n4 %s 0\n' $((now - 3600)) "$now" >"$S01/closed.tsv"
wait_ticks 4

# A session taken over after a restart: the loop is down while B06's PR merges.
kill "$loop1s"; wait "$loop1s" 2>/dev/null
sleep 0.5   # nothing to observe: the loop is gone; the session must still be alive a moment after it
c6=$(cat "$S01/child.B06.1" 2>/dev/null)
s01ok "S01 setup: stopping the loop leaves B06's session running" grp_up "$p6"
echo "17 node/B06-n6" >>"$S01/merged.tsv"; printf '17 node/B06-n6 %s 1\n' "$(date +%s)" >>"$S01/closed.tsv"
loop4; loop2s=$lp4
s01ok "S01-AC-1: a taken-over session whose PR merged: its process group is gone within a tick" waitf 4 grp_gone "$p6"
s01ok "S01-AC-1: (taken over) and its child with it" waitf 2 dead "$c6"
s01ok "S01-AC-1: (taken over) one status-log event names the node and the merged PR" waitf 3 evis B06 17 1
s01ok "S01-AC-1: (taken over) its evidence is archived to state/archive/B06-out" waitf 3 test -f "$state/archive/B06-out/brief.md"
s01ok "S01-AC-1: (taken over) its worktree is removed" waitf 3 test ! -d "$wt4/B06"
m6=$(polls "$S01/polls")
wait_polls "$S01/polls" "$m6" 2
s01ok "S01-AC-1: (taken over) the event is not repeated" test "$(ev B06 17)" = 1
s01ok "S01-AC-3: after the restart the sessions of B03, B04 and B05 still run" bash -c "$(declare -f grp_gone grp_up); grp_up $p3 && grp_up $p4 && grp_up $p5"

kill "$loop2s"; wait "$loop2s" 2>/dev/null
s01_cleanup

loop_end
