#!/bin/bash
# S01-AC-2: a session whose PR is closed unmerged is stopped. Part of the end-to-end test of scheduler/loop.sh.
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"   # the runner runs *.test.sh with sh, except loop.test.sh
. "$(dirname "$0")/testdata/lib/loop-prelude.sh"
. "$src/testdata/lib/loop-fakes.sh"
. "$src/testdata/lib/loop-s01.sh"

loop4; loop1s=$lp4
# the run of loop-s01.test.sh up to B01's stop, its checks made there: here a wait prints FAIL only when it runs out
waitf 20 sh -c "[ \$(ls '$S01'/child.B0[1-6].1 2>/dev/null | wc -l) = 6 ]" || fail "S01 setup: six sessions run (in $(basename "$0"))"
p1=$(pg B01) p2=$(pg B02) p3=$(pg B03) p4=$(pg B04) p5=$(pg B05)
c2=$(cat "$S01/child.B02.1" 2>/dev/null)
wait_until 5 s01_started 6
now=$(date +%s)
echo node/B04-n4 >"$S01/open.txt"   # open.txt first, as in loop-s01.test.sh
wait_polls "$S01/polls" "$(polls "$S01/polls")" 2
printf '13 node/B03-n3 %s 0\n14 node/B04-n4 %s 0\n' $((now - 3600)) "$now" >"$S01/closed.tsv"
wait_ticks 4   # as in loop-s01.test.sh, where the S01-AC-3 checks are made after these ticks
echo "11 node/B01-n1" >>"$S01/merged.tsv"; printf '11 node/B01-n1 %s 1\n' "$(date +%s)" >>"$S01/closed.tsv"
{ waitf 10 grp_gone "$p1" && waitf 10 evis B01 11 1 && waitf 10 test -f "$state/archive/B01-out/brief.md" && waitf 10 test ! -d "$wt4/B01"; } ||
	fail "S01 setup: B01 is stopped after its PR merged (in $(basename "$0"))"

printf '12 node/B02-n2 %s 0\n' "$(date +%s)" >>"$S01/closed.tsv"
s01ok "S01-AC-2: a session whose PR was closed unmerged while it ran: its process group is gone within a tick" waitf 4 grp_gone "$p2"
s01ok "S01-AC-2: and its child with it" waitf 2 dead "$c2"
s01ok "S01-AC-2: one status-log event names the node and the closed PR" waitf 3 evis B02 12 1
s01ok "S01-AC-2: its FAILED marker names the closed PR" waitf 3 sh -c "head -n1 '$state/node/B02/FAILED' | grep -qE '#12([^0-9]|\$)'"
s01ok "S01-AC-2: its worktree remains" test -d "$wt4/B02"
s01ok "S01-AC-2: its branch remains" git -C "$data4/repos/sc" rev-parse --verify -q node/B02-n2
wait_ticks 4   # the old fixed sleep was 3 s: a did-not-happen check waits at least that many ticks
s01ok "S01-AC-2: the event is not repeated on later ticks" test "$(ev B02 12)" = 1
s01ok "S01-AC-2: it is not started on later ticks" test "$(s01runs B02)" = 1
rm -f "$state/node/B02/FAILED"
s01ok "S01-AC-2: after FAILED is deleted it starts again, as start 1 of 2" waitf 4 countis 'started B02 .*start 1 of 2' 2
m2b=$(polls "$S01/polls")   # the two checks on the new session are made below, three ticks on

wait_polls "$S01/polls" "$m2b" 3
s01ok "S01-AC-2: the new session is not stopped for the PR closed before it began" sh -c "[ \"\$(cat '$S01/runs.B02')\" = 2 ] && kill -0 \"\$(cat '$state/node/B02/session.pid')\""
s01ok "S01-AC-2: and no second FAILED is written" test ! -e "$state/node/B02/FAILED"

# S01-AC-3 again, after every tick of this loop with #13 and #14 closed: the base checked "B03, B04 and B05 still run" once
# more after these ticks (and after the takeover, now in loop-s01-takeover.test.sh), as loop-s01.test.sh does. Prints only on failure: the PASS labels
# stay where they are; no wait of its own (the ticks above have passed).
grp_up "$p3" && grp_up "$p4" && grp_up "$p5" || fail "S01-AC-3: the sessions of B03, B04 and B05 still run after the later ticks (in $(basename "$0"))"
# (the tick's own lists, "open=[B04] merged-prs=[B01]", are left out: by now the stop lines of B01 and B02 carry them)
s01stop345() { sed 's/[a-z-]*=\[[^]]*\]//g' "$state/status.log" | grep -i stop | grep -E 'B0[345]'; }
s01stop345 >/dev/null && { fail "S01-AC-3: no stop event for them after the later ticks (in $(basename "$0"))"; s01stop345 | sed 's/^/      /'; }

kill "$loop1s"; wait "$loop1s" 2>/dev/null
s01_cleanup

loop_end
