#!/bin/bash
# S07: the start queue. Part of the end-to-end test of scheduler/loop.sh (fixture: testdata/lib/loop-s07.sh). Phase C.
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"   # the runner runs *.test.sh with sh, except loop.test.sh
. "$(dirname "$0")/testdata/lib/loop-prelude.sh"
. "$src/testdata/lib/loop-s07.sh"

# -- Phase C: the throttle holds from the second turn; the waiting records; the next start comes at the first turn after it opens
# qa: triage #7, A02 (M), A03 (L); qb: triage #9, B01 (S), B04 (L). No seeds: the loops write the records.
qsetup C "A02:M A03:L" "B01:S B04:L"
echo '[{"number": 7}]' >"$q/issues.qa.json"; echo '[{"number": 9}]' >"$q/issues.qb.json"
# tick 3 (qa): live at qb's turns through a loaded tick, so the first turn is t7's (see the fixture); tick 3 (qb): it asks
# alone after the reopening and must be live in the tick that first reads the opened throttle (w < 8 s), and live at qa's
# asks then (else qa takes A02). Gap 6 s: the hold after the first turn comes before any later turn, also when a loop had
# read the throttle open just before the hold (the old gap of 1 s was shorter than a loaded tick).
# As at the base, qa starts first: #7 and #9 are both triages with no seeds, so the older record goes first; qb starts
# only after qa has written its records and listed #7, so #7's record is no later than #9's, and a tie (same second)
# goes to qa by the repository's name (turn.py). Both loops start with the throttle holding and list every unit first.
QENV="SCHED_START_GAP=6 SCHED_STARVE=3600"
t_c0=$(date +%s)
qhold; qloop qa 3 $QENV; qwait 8 qfirst qa; qwait 8 qlisted qa "#7" A02 A03
qloop qb 3 $QENV; qwait 8 qfirst qb
qcompete "#7 A02 A03" "#9 B01 B04"
qopen
qwait 12 qhave t7; qhold
# the gap (6 s) is longer than a tick (3 s) now: wait until each loop has begun a tick after t7's start + the gap (its ask
# at the end of that tick comes after the gap, with the throttle holding), then a tick more so that ask has been made
qpast_gap() { local l t; t=$(qt t7 | awk -F. '{ print $1 + 6 }'); for l in qa qb; do [ "$(cat "$qd/state/$l/heartbeat" 2>/dev/null || echo 0)" -gt "$t" ] || return 1; done; }
qwait 8 qpast_gap
qticks 1 qa qb
qticks 3 qa qb
qok "S07-AC-1: the throttle holding from the second turn: only the first unit started" test "$(qseq)" = "t7"
qrecs() { local f; for f in qa/node/A02 qa/node/A03 qb/node/B01 qb/node/B04 qb/issue/9; do [ -e "$qd/state/$f/waiting" ] || return 1; done; }
qwait 3 qrecs
qrecs_valid() { local f r; for f in qa/node/A02 qa/node/A03 qb/node/B01 qb/node/B04 qb/issue/9; do r=$(cat "$qd/state/$f/waiting" 2>/dev/null) || return 1; case $r in ''|*[!0-9]*) return 1 ;; esac; [ "$r" -ge $((t_c0 - 1)) ] && [ "$r" -le "$(date +%s)" ] || return 1; done; }
qok "S07-AC-5: each unit found waiting has a record (epoch seconds, no earlier than the loop's start)" qrecs_valid
qok "S07-AC-5: the record of the started triage is removed" test ! -e "$qd/state/qa/issue/7/waiting"
ra02=$(qrec qa node/A02); ra03=$(qrec qa node/A03); rb04=$(qrec qb node/B04); rb9=$(qrec qb issue/9)
touch "$HOME/STOP-qa"; qwait 6 sh -c "! kill -0 ${qp[qa]} 2>/dev/null"; rm -f "$HOME/STOP-qa"
qloop qa 3 $QENV; qwait 8 sh -c "[ \$(grep -c 'loop started' '$(qlog qa)') -ge 2 ]"; qticks 2
qok "S07-AC-5: a record survives a loop restart with its time unchanged" test -n "$ra02" -a "$(qrec qa node/A02)" = "$ra02" -a "$(qrec qa node/A03)" = "$ra03"
echo "Q1: q" >"$qd/state/qa/node/A03/QUESTION.md"; touch "$qd/state/qb/node/B04/FAILED"; echo '[]' >"$q/issues.qb.json"
qgone_after() { [ -n "$2" ] || return 1; qwait 5 test ! -e "$1"; }
qok "S07-AC-5: a record is removed when the node gets a QUESTION.md" qgone_after "$qd/state/qa/node/A03/waiting" "$ra03"
qok "S07-AC-5: a record is removed when the node gets a FAILED" qgone_after "$qd/state/qb/node/B04/waiting" "$rb04"
qok "S07-AC-5: a record is removed when the issue's label is removed" qgone_after "$qd/state/qb/issue/9/waiting" "$rb9"
echo "Q1: a" >"$qd/state/qa/node/A03/ANSWER.md"; rm -f "$qd/state/qb/node/B04/FAILED"
qnewer() { [ -n "$2" ] && qwait 5 test -e "$1" && [ "$(cat "$1")" -gt "$2" ]; }
qok "S07-AC-5: an answered node's wait restarts: a new record, later than the old" qnewer "$qd/state/qa/node/A03/waiting" "$ra03"
qok "S07-AC-5: a node that lost its FAILED waits anew: a new record, later than the old" qnewer "$qd/state/qb/node/B04/waiting" "$rb04"
qopen; t_open=$(date +%s.%N)
qwait_n 8 2; wait_until 15 qev_ge 2
# "at the first turn after the throttle opens" (the old window of 2.6 s was a tick and a gap of 1 s): B01 is the next start
# after the opening, in the starts and in the status logs (no other start event), and qb started it in the tick that
# first read the opened throttle: that tick logs "throttle released" (qb held since the hold after t7), at or after the
# opening's second, and B01's tick (its heartbeat, qhb) had begun by that line's second (a later tick begins at least
# SCHED_TICK after the second in which the one before ended, assuming qb's pause after the tick that logs "throttle
# released" does not end early: loop.sh's pause() returns at once when one of qb's sessions exits or a marker of qb
# changes (fingerprint()); qb runs no session, and after the opening the test changes no marker of qb). No more than one of qb's ticks began (asked for the merged
# PRs, before it reads the throttle) between the opening and B01's start.
qreleased() { grep '; throttle released' "$(qlog qb)" | awk '{ print $1 }' | while read -r t; do date -d "$t" +%s; done | awk -v a="${t_open%.*}" '$1 >= a { print; exit }'; }
qsecond_soon() { local r h; r=$(qreleased) h=$(qhb B01); [ "$(sort -n "$q/starts.log" | sed -n 2p | awk '{ print $3 }')" = B01 ] && [ "$(qev '' | wc -l)" = 2 ] && awk -v a="$t_open" -v b="$(qt B01)" 'BEGIN { exit !(b - a >= 0) }' && [ "$(qtickt qb "$t_open" "$(qt B01)")" -le 1 ] && [ -n "$r" ] && [ -n "$h" ] && [ "$h" -le "$r" ]; }
qok "S07-AC-1: the next unit (the S node) starts at the first turn after the throttle opens, within 2.6 s" qsecond_soon
qok "S07-AC-5: the started node's record is removed" test ! -e "$qd/state/qb/node/B01/waiting" -a -n "$ra03"
qstop


loop_end
