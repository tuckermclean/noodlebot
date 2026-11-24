#!/bin/bash
# S13: the machine budget SCHED_MACHINE_MAX in the loops (S13-AC-2). Fixture: testdata/lib/loop-s07.sh (two loops, o/qa and
# o/qb under one runtime root, fake sessions that run until $q/end.<id>). Scratch paths are under $tmp/S13.
# What loop.sh must do with SCHED_MACHINE_MAX=1, SCHED_RAMP=1 (turn.py ask prints nothing, took exits 3, count prints
# "<n> of <N> sessions running on the machine"):
#  - a unit the budget holds: the loop has a waiting unit, asked for a turn, got none, and the count is at the budget. It writes
#    one status-log line containing "machine budget" and "1 of 1 sessions running on the machine", and no further such line
#    until a start of its goes through (so one line however many ticks the hold lasts);
#  - a released node (node/<ID>/RELEASE, throttle holding) whose `turn.py took` the budget refuses (exit 3) is not started and
#    is not a failed took: the loop writes one line "<ID>: RELEASE found, but 1 of 1 sessions running on the machine
#    (machine budget); it waits" per hold and keeps the release (the marker or the loop's memory), so that the node starts,
#    released past the throttle which still holds, once a session ends;
#  - the held unit starts once the running session ends, whichever loop it belongs to; never two sessions at once.
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"   # the runner runs *.test.sh with sh, except loop.test.sh
. "$(dirname "$0")/testdata/lib/loop-prelude.sh"
. "$src/testdata/lib/loop-s07.sh"

# qsetup builds $q under $tmp: for this file $tmp/S13 (the real $tmp is back after the call; the trap uses it)
s13setup() { local real=$tmp; mkdir -p "$real/S13"; tmp=$real/S13; qsetup "$@"; tmp=$real; }
# the most session.pid files of both loops that named a live process at once, sampled in the background into $q/maxlive
s13live() { local n=0 f p; for f in "$qd"/state/*/node/*/session.pid; do p=$(cat "$f" 2>/dev/null) && [ -n "$p" ] && kill -0 "$p" 2>/dev/null && n=$((n + 1)); done; echo $n; }
s13sample() { local m=0 n; while :; do n=$(s13live); [ "$n" -gt "$m" ] && { m=$n; echo "$m" >"$q/maxlive.new"; mv "$q/maxlive.new" "$q/maxlive"; }; sleep 0.05; done; }
s13lines() { grep -c "$2" "$(qlog "$1")" 2>/dev/null; }
s13hold_line() { grep -qE 'machine budget.*1 of 1 sessions running on the machine|1 of 1 sessions running on the machine.*machine budget' "$(qlog qb)"; }
s13holds() { grep -cE 'machine budget' "$(qlog qb)" 2>/dev/null; }
s13rel_lines() { grep -E 'A03: RELEASE found.*machine budget' "$(qlog qa)" 2>/dev/null | wc -l; }
s13released_ok() { [ "$(qseq)" = "A02 B01 A03" ] && grep -q "^hold" "$q/usage"; }
s13rel_line() { [ "$(s13rel_lines)" -ge 1 ]; }

s13setup S13 "A02:S A03:L" "B01:S"
echo 0 >"$q/maxlive"
# order: A02 (S, waited 300 s), then B01 (S, 200 s), then A03 (L): the first unit of the order is the other loop's after A02
qseed qa node/A02 300; qseed qa node/A03 100; qseed qb node/B01 200
# tick 2: with two loops the order across them needs w < 3 s (see the fixture)
QENV="SCHED_MACHINE_MAX=1 SCHED_START_GAP=1 SCHED_STARVE=3600"
qboth 2 2 $QENV
qcompete "A02 A03" "B01"
s13sample & spid=$!; pids+=("$spid")
qopen
qwait 12 qhave A02
qwait 12 s13hold_line
qticks 3 qa qb
qok "S13-AC-2: the first unit of the order (A02) starts" test "$(qseq)" = "A02"
qok "S13-AC-2: the held loop's unit (B01) does not start while A02 runs" test "$(qn)" = 1
qok "S13-AC-2: the hold is one status-log line naming the machine budget and 'N of N sessions running on the machine'" test "$(s13holds)" = 1
touch "$q/end.A02"
qwait 12 qhave B01
qok "S13-AC-2: when A02 ends, the first unit of the order (B01, the other loop's) starts" test "$(qseq)" = "A02 B01"
qticks 3 qa qb
qok "S13-AC-2: A03 (qa) is held while B01 runs: not started" test "$(qn)" = 2
qok "S13-AC-2: a start that went through ends the hold: still one line in qb (B01's)" test "$(s13holds)" = 1
# a released node waits the same way, the throttle holding
qhold
qticks 1 qa qb
mkdir -p "$qd/state/qa/node/A03"; touch "$qd/state/qa/node/A03/RELEASE"
qwait 12 s13rel_line
qticks 3 qa qb
qok "S13-AC-2: a released node (A03) is not started while B01 runs" test "$(qn)" = 2
qok "S13-AC-2: a refused release is one status-log line naming the machine budget (not a failed took)" test "$(s13rel_lines)" = 1
qok "S13-AC-2: the refused release is not reported as a failed turn.py took" sh -c "! grep -q 'turn.py took failed' '$(qlog qa)'"
touch "$q/end.B01"
qwait 12 qhave A03
qok "S13-AC-2: the released node starts once a session ends, the throttle still holding" s13released_ok
kill "$spid" 2>/dev/null; wait "$spid" 2>/dev/null
qok "S13-AC-2: never more than one session at once across both loops (session.pid files sampled)" test "$(cat "$q/maxlive")" = 1
qstop

loop_end
