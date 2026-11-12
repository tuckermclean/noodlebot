#!/bin/bash
# S07: the start queue. Part of the end-to-end test of scheduler/loop.sh (fixture: testdata/lib/loop-s07.sh). Phase I.
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"   # the runner runs *.test.sh with sh, except loop.test.sh
. "$(dirname "$0")/testdata/lib/loop-prelude.sh"
. "$src/testdata/lib/loop-s07.sh"

# -- Phase I: a spec-PR update, a follow-up, a resumed node (an answered one, not S06's idle session) and a fresh node with
# no Size each start with a turn event naming the kind (L for the missing Size) and the wait, in the AC-2 order.
# qa: update PR 31 (waited 100 s), follow-up A02 (200), resumed A03 (300), fresh A04 without Size (500); qb: B01 (S, 50).
qsetup I "A02:S A03:S A04:" "B01:S"; qghx
git -C "$q/qa.git" branch spec/u1 main
printf '31 spec/u1 oid31 true CONFLICTING\n' >"$q/open.qa.tsv"; echo "20 node/A02-u-A02" >"$q/merged.qa.tsv"
mkdir -p "$qd/state/qa/node/A02" "$qd/state/qa/node/A03"
for i in A02 A03; do echo "Q1: q" >"$qd/state/qa/node/$i/QUESTION.md"; echo "Q1: a" >"$qd/state/qa/node/$i/ANSWER.md"; done
git -C "$qd/repos/qa" worktree add -q -b node/A03-u-A03 "$qd/worktrees/qa/A03" origin/main
git -C "$qd/worktrees/qa/A03" -c user.name=t -c user.email=t@t commit -q --allow-empty -m wip
qseed qa pr/31 100; qseed qa node/A02 200; qseed qa node/A03 300; qseed qa node/A04 500; qseed qb node/B01 50
# tick 3: both loops stay live through a loaded tick (B01's event names qa/A04: qa is live at qb's turn); see the fixture
qboth 3 3 SCHED_START_GAP=1 SCHED_STARVE=3600
qcompete "PR#31:update A02:followup A03:resumed A04:fresh" "B01:fresh"
qopen
qrun_until 30 5
qok "S07-AC-2: the order: resumed and follow-up and update by wait (A03 300 s, A02 200 s, PR 31 100 s), then S (B01), then the node with no Size as L (A04)" test "$(qseq)" = "A03 A02 t31 B01 A04"
qok "S07-AC-5: the update's event names its kind and wait" qev_has 'update' '; turn: update, waited [^,;]+'
qok "S07-AC-5: the follow-up's event names its kind and wait" qev_has 'A02 ' '; turn: followup, waited [^,;]+'
qok "S07-AC-5: the resumed node's event names its kind and wait" qev_has 'A03 ' '; turn: resumed, waited [^,;]+'
qok "S07-AC-5: the fresh node with no Size is named L, with its wait" qev_has 'A04 ' '; turn: L, waited [^,;]+'
qok "S07-AC-5: the update's event names the unit that waited longer and still waited (A04)" qev_has 'update' 'ahead of .*A04'
qok "S07-AC-5: B01's event names A04, which waited longer and still waited" qev_has 'B01 ' 'ahead of .*qa/A04'
qok "S07-AC-5: A04's event, the last, names nobody ahead" qev_hasnt 'A04 ' 'ahead of'
qstop


loop_end
