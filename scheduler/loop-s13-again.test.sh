#!/bin/bash
# S13 (fix round): the machine budget SCHED_MACHINE_MAX in the loops, part two (S13-AC-2). Fixture as loop-s13.test.sh:
# testdata/lib/loop-s07.sh (two loops, o/qa and o/qb under one runtime root, fake sessions that run until $q/end.<id>); scratch
# paths are under $tmp/S13. One phase, SCHED_MACHINE_MAX=1e0: turn.py reads it as 1 (the loop must take the budget and the
# "full" decision from turn.py's `count`, not from its own reading of the variable). What loop.sh must do:
#  - a hold ends when a start of that loop goes through; the next hold is a new status-log line (one per hold, never more over
#    several ticks): qb holds B01 behind A02 (line 1), starts B01 once A02 ends, then holds B02 behind B01 (line 2);
#  - a node released (RELEASE, throttle holding) and held by the budget gets a line "<ID>: RELEASE found, but ... (machine budget);
#    it waits"; when that release ended another way (the throttle opened: the node is an ordinary waiting unit) a later release,
#    held again, gets a new line.
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"   # the runner runs *.test.sh with sh, except loop.test.sh
. "$(dirname "$0")/testdata/lib/loop-prelude.sh"
. "$src/testdata/lib/loop-s07.sh"

# qsetup builds $q under $tmp: for this file $tmp/S13 (the real $tmp is back after the call; the trap uses it)
s13asetup() { local real=$tmp; mkdir -p "$real/S13"; tmp=$real/S13; qsetup "$@"; tmp=$real; }
s13alive() { local n=0 f p; for f in "$qd"/state/*/node/*/session.pid; do p=$(cat "$f" 2>/dev/null) && [ -n "$p" ] && kill -0 "$p" 2>/dev/null && n=$((n + 1)); done; echo $n; }
s13asample() { local m=0 n; while :; do n=$(s13alive); [ "$n" -gt "$m" ] && { m=$n; echo "$m" >"$q/maxlive.new"; mv "$q/maxlive.new" "$q/maxlive"; }; sleep 0.05; done; }
s13aholds() { grep -cE 'machine budget' "$(qlog qb)" 2>/dev/null; }
s13aholds_ge() { [ "$(s13aholds)" -ge "$1" ]; }
s13arel_lines() { grep -E 'A03: RELEASE found.*machine budget' "$(qlog qa)" 2>/dev/null | wc -l; }
s13arel_ge() { [ "$(s13arel_lines)" -ge "$1" ]; }
s13aopen_line() { grep -qE 'A03: RELEASE found, the throttle is open' "$(qlog qa)"; }

s13asetup S13again "A02:S A03:L" "B01:S B02:L"
echo 0 >"$q/maxlive"
# order: A02 (S, waited 300 s), B01 (S, 200 s), B02 (L, 100 s), A03 (L, 50 s)
qseed qa node/A02 300; qseed qa node/A03 50; qseed qb node/B01 200; qseed qb node/B02 100
# tick 2: with two loops the order across them needs w < 3 s (see the fixture)
QENV="SCHED_MACHINE_MAX=1e0 SCHED_START_GAP=1 SCHED_STARVE=3600"
qboth 2 2 $QENV
qcompete "A02 A03" "B01 B02"
s13asample & spid=$!; pids+=("$spid")
qopen
qwait 8 qhave A02
qwait 8 s13aholds_ge 1
qticks 2 qa qb
qok "S13-AC-2: A02 runs and the loop takes the budget from turn.py (SCHED_MACHINE_MAX=1e0): qb's hold is one line" test "$(s13aholds)" = 1
qok "S13-AC-2: only A02 started while it runs" test "$(qseq)" = "A02"
# the running session ends: B01 starts in qb (the hold ends), B02 is then held by B01: a new hold, a second line
touch "$q/end.A02"
qwait 8 qhave B01
qwait 8 s13aholds_ge 2
qticks 2 qa qb
qok "S13-AC-2: when A02 ends B01 starts in qb" test "$(qseq)" = "A02 B01"
qok "S13-AC-2: a start of qb went through, so its next hold (B02 behind B01) is a new line: two hold lines, one per hold" test "$(s13aholds)" = 2
# a node of qa is released, held by the budget: one line
qhold
qticks 1 qa qb
mkdir -p "$qd/state/qa/node/A03"; touch "$qd/state/qa/node/A03/RELEASE"
qwait 8 s13arel_ge 1
qticks 2 qa qb
qok "S13-AC-2: a released node (A03) held by the budget: one line naming the machine budget" test "$(s13arel_lines)" = 1
# the throttle opens: the release is used up, A03 is an ordinary waiting unit held by the budget
qopen
qwait 8 s13aopen_line
# held again, released again: a new line
qhold
qticks 1 qa qb
mkdir -p "$qd/state/qa/node/A03"; touch "$qd/state/qa/node/A03/RELEASE"
qwait 8 s13arel_ge 2
qticks 2 qa qb
qok "S13-AC-2: a release that ended another way, released and held again: a second line naming the machine budget" test "$(s13arel_lines)" = 2
qok "S13-AC-2: neither A03 nor B02 started while B01 runs" test "$(qseq)" = "A02 B01"
qok "S13-AC-2: no hold line of qb beyond the two, over all these ticks" test "$(s13aholds)" = 2
kill "$spid" 2>/dev/null; wait "$spid" 2>/dev/null
qok "S13-AC-2: never more than one session at once across both loops (session.pid files sampled)" test "$(cat "$q/maxlive")" = 1
qstop

loop_end
