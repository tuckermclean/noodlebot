#!/bin/bash
# S01-AC-3 and S01-AC-1: a session whose PR is done is stopped; closed PRs that do not apply stop nothing. Part of the end-to-end test of scheduler/loop.sh.
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"   # the runner runs *.test.sh with sh, except loop.test.sh
. "$(dirname "$0")/testdata/lib/loop-prelude.sh"
. "$src/testdata/lib/loop-fakes.sh"
. "$src/testdata/lib/loop-s01.sh"

loop4; loop1s=$lp4
s01ok "S01 setup: six sessions run, each with a child of its own" waitf 20 sh -c "[ \$(ls '$S01'/child.B0[1-6].1 2>/dev/null | wc -l) = 6 ]"
p1=$(pg B01) p2=$(pg B02) p3=$(pg B03) p4=$(pg B04) p5=$(pg B05) p6=$(pg B06)
c1=$(cat "$S01/child.B01.1" 2>/dev/null) c2=$(cat "$S01/child.B02.1" 2>/dev/null)
s01ok "S01 setup: a session's child is in the session's process group" sh -c "[ \"\$(ps -o pgid= -p '$c1' | tr -d ' ')\" = '$p1' ]"
# the loop has logged the start of all six sessions (the old fixed sleep of 2 s let it settle)
wait_until 5 s01_started 6
now=$(date +%s)
# open.txt first: the loop reads both files in one tick, and B04's open PR must be there when its closed PR is
echo node/B04-n4 >"$S01/open.txt"
wait_polls "$S01/polls" "$(polls "$S01/polls")" 2   # two ticks that read open.txt, so none sees #14 closed without its open PR
printf '13 node/B03-n3 %s 0\n14 node/B04-n4 %s 0\n' $((now - 3600)) "$now" >"$S01/closed.tsv"
wait_ticks 4   # the old fixed sleep was 3.5 s: a did-not-happen check waits that many ticks, rounded up
s01ok "S01-AC-3: a PR closed before the session started does not stop it" grp_up "$p3"
s01ok "S01-AC-3: a closed PR does not stop the session of a node that also has an open PR" grp_up "$p4"
s01ok "S01-AC-3: nodes with no PR are untouched" grp_up "$p5"
s01ok "S01-AC-3: no stop event for them" sh -c "! grep -i stop '$state/status.log' | grep -qE 'B0[345]'"

echo "11 node/B01-n1" >>"$S01/merged.tsv"; printf '11 node/B01-n1 %s 1\n' "$(date +%s)" >>"$S01/closed.tsv"
s01ok "S01-AC-1: a session whose PR merged while it ran: its process group is gone within a tick" waitf 4 grp_gone "$p1"
s01ok "S01-AC-1: and its child with it" waitf 2 dead "$c1"
s01ok "S01-AC-1: one status-log event names the node and the merged PR" waitf 3 evis B01 11 1
s01ok "S01-AC-1: its evidence is archived to state/archive/B01-out" waitf 3 test -f "$state/archive/B01-out/brief.md"
s01ok "S01-AC-1: its worktree is removed" waitf 3 test ! -d "$wt4/B01"
m1=$(polls "$S01/polls")   # its "not repeated" checks are made below, three ticks on
wait_polls "$S01/polls" "$m1" 3
s01ok "S01-AC-1: the event is not repeated on later ticks" test "$(ev B01 11)" = 1
s01ok "S01-AC-1: the merged node is not started again" test "$(s01runs B01)" = 1

# S01-AC-3 again, after every tick of this loop with #13 and #14 closed: the base checked "B03, B04 and B05 still run" once
# more after these ticks (and after the takeover, now in loop-s01-takeover.test.sh). Prints only on failure: the PASS labels
# stay where they are; no wait of its own (the ticks above have passed).
grp_up "$p3" && grp_up "$p4" && grp_up "$p5" || fail "S01-AC-3: the sessions of B03, B04 and B05 still run after the later ticks (in $(basename "$0"))"
# (the tick's own lists, "open=[B04] merged-prs=[B01]", are left out: by now the stop line of B01 carries them)
s01stop345() { sed 's/[a-z-]*=\[[^]]*\]//g' "$state/status.log" | grep -i stop | grep -E 'B0[345]'; }
s01stop345 >/dev/null && { fail "S01-AC-3: no stop event for them after the later ticks (in $(basename "$0"))"; s01stop345 | sed 's/^/      /'; }

kill "$loop1s"; wait "$loop1s" 2>/dev/null
s01_cleanup

loop_end
