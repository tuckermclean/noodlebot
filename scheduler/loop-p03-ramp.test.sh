#!/bin/bash
# P03-AC-4 under S07's start queue (SCHED_RAMP=1): a node released past the throttle takes no turn, but its start is recorded in
# state/starts.json (turn.py took) so the next start on a turn comes a gap after it. Part of the end-to-end test of
# scheduler/loop.sh (fixture: testdata/lib/loop-s07.sh); loop A only, qb has no loop. The fake turn.py in front of the real
# one logs its calls to $q/turn.calls ("<command> <key>"), and fails `took` while $q/took.fail exists.
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"   # the runner runs *.test.sh with sh, except loop.test.sh
. "$(dirname "$0")/testdata/lib/loop-prelude.sh"
. "$src/testdata/lib/loop-s07.sh"

# pwrap: the wrapper around the real turn.py
pwrap() {
	cp "$qnb/scheduler/turn.py" "$q/turn.real.py"
	sed "s|@Q@|$q|g" >"$qnb/scheduler/turn.py" <<'PYEOF'
import os, subprocess, sys
q = "@Q@"
a = sys.argv[1:]
k = a[1] if len(a) > 1 and not a[1].startswith("--") else ""
with open(q + "/turn.calls", "a") as f:
    f.write(("%s %s" % (a[0], k)).strip() + "\n")
if a and a[0] == "took" and os.path.exists(q + "/took.fail"):
    sys.stderr.write("fake turn.py took failure\n")
    sys.exit(1)
sys.exit(subprocess.call(["python3", "-I", q + "/turn.real.py"] + a))
PYEOF
	: >"$q/turn.calls"
}
pcalled() { grep -qx "$1" "$q/turn.calls"; }
pline() { grep -nx "$1" "$q/turn.calls" | head -n1 | cut -d: -f1; }
srec() { python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d["repo"]+"/"+d["unit"]+"@"+str(int(d["time"])))' "$qd/state/starts.json" 2>/dev/null; }
# prel <ID>: the release line's own text (after the status prefix)
prel() { grep -F "$1: " "$(qlog qa)" | grep -i 'RELEASE' | sed 's/^[^;]*; //'; }
prel_logged() { [ -n "$(prel "$1")" ]; }
release() { mkdir -p "$qd/state/qa/node/$1"; date -u +%FT%TZ >"$qd/state/qa/node/$1/RELEASE"; }
no_release() { [ ! -e "$qd/state/qa/node/$1/RELEASE" ]; }

# -- Phase A: the throttle holds; R1 (ready) is released, then the throttle opens with U2 waiting
qsetup PA "R1:S U2:S" "B01:S"; pwrap
qhold; qloop qa 1 SCHED_START_GAP=6 SCHED_STARVE=3600
qwait 8 qfirst qa
release R1
qwait 8 qhave R1; wait_until 5 qev_ge 1
qticks 2
qok "P03-AC-4: (SCHED_RAMP=1) a RELEASE for a ready node the throttle holds starts it, at once" test "$(qseq)" = "R1"
qok "P03-AC-4: (SCHED_RAMP=1) its status event says it was released past the throttle" grep -q 'R1: released past the throttle' "$(qlog qa)"
qok "P03-AC-4: (SCHED_RAMP=1) it starts without a turn: no 'turn:' in its start event" sh -c "! grep '; started R1 ' '$(qlog qa)' | grep -q '; turn: '"
qok "P03-AC-4: (SCHED_RAMP=1) its start is recorded in starts.json (unit = its key, repo qa)" sh -c "[ \"\$(python3 -I -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d[\"repo\"]+\"/\"+d[\"unit\"])' '$qd/state/starts.json' 2>/dev/null)\" = qa/R1 ]"
qok "P03-AC-4: (SCHED_RAMP=1) the loop asked turn.py to record it: 'took R1'" pcalled "took R1"
qok "P03-AC-4: (SCHED_RAMP=1) it is started once and counted: starts is 1, one session" sh -c "[ \"\$(cat '$qd/state/qa/node/R1/starts')\" = 1 ] && [ '$(qn)' = 1 ]"
qok "P03-AC-4: (SCHED_RAMP=1) its waiting record is removed" test ! -e "$qd/state/qa/node/R1/waiting"
qok "P03-AC-4: (SCHED_RAMP=1) its RELEASE is removed" no_release R1
qok "P03-AC-4: (SCHED_RAMP=1) the throttle still holds: U2 is not started" test "$(qseq)" = "R1"
qopen
qwait 12 qhave U2; wait_until 5 qev_ge 2
qok "P03-AC-4: (SCHED_RAMP=1) the throttle opens: U2 starts on a turn" test "$(qseq)" = "R1 U2"
qok "P03-AC-4: (SCHED_RAMP=1) U2's start comes at least the gap (6 s, less a second) after the released R1's" sh -c "awk -v a='$(qt R1)' -v b='$(qt U2)' 'BEGIN { exit !(b - a >= 5) }'"
qok "P03-AC-4: (SCHED_RAMP=1) U2's start event is on a turn" qev_has 'U2 ' '; turn: '
qstop

# -- Phase B: the throttle is open, the queue is on, no turn yet (a start a second ago, gap 300 s): a RELEASE starts nothing out of turn
qsetup PB "X1:S" "B01:S"; pwrap
now=$(date +%s); mkdir -p "$qd/state"
printf '{"time": %s, "repo": "qb", "unit": "B01"}\n' "$now" >"$qd/state/starts.json"
qloop qa 1 SCHED_START_GAP=300 SCHED_STARVE=3600
qwait 8 qfirst qa
release X1
qwait 8 prel_logged X1
qticks 3
qok "P03-AC-4: (SCHED_RAMP=1, throttle open) a RELEASE starts nothing out of turn: X1 waits for its turn" test "$(qn)" = 0
qok "P03-AC-4: (SCHED_RAMP=1, throttle open) its release line says the throttle is open and the node waits for its turn" sh -c "l=\$(grep -F 'X1: ' '$(qlog qa)' | grep -i RELEASE | sed 's/^[^;]*; //'); printf '%s\n' \"\$l\" | grep -qiE 'throttle (is |was )?open' && printf '%s\n' \"\$l\" | grep -qiE 'turn' && ! printf '%s\n' \"\$l\" | grep -qi 'past the throttle'"
qok "P03-AC-4: (SCHED_RAMP=1, throttle open) no 'took' for it: the start record is untouched" sh -c "! grep -q '^took' '$q/turn.calls' && [ \"\$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))[\"unit\"])' '$qd/state/starts.json')\" = B01 ]"
qok "P03-AC-4: (SCHED_RAMP=1, throttle open) its RELEASE is removed" no_release X1
qok "P03-AC-4: (SCHED_RAMP=1, throttle open) it is still waiting (waiting record kept)" test -e "$qd/state/qa/node/X1/waiting"
printf '{"time": %s, "repo": "qb", "unit": "B01"}\n' $((now - 1000)) >"$qd/state/starts.json.new" && mv "$qd/state/starts.json.new" "$qd/state/starts.json"
qwait 8 qhave X1
qok "P03-AC-4: (SCHED_RAMP=1, throttle open) when its turn comes it starts" test "$(qseq)" = "X1"
qstop

# -- Phase C: a failing `turn.py took` is logged and starts nothing
qsetup PC "R1:S" "B01:S"; pwrap
: >"$q/took.fail"
qseed qa/node R1 1000; rc0=$(qrec qa/node R1)
qhold; qloop qa 1 SCHED_START_GAP=1 SCHED_STARVE=3600
qwait 8 qfirst qa
release R1
wait_until 8 grep -qi 'took' "$(qlog qa)"
qticks 2
qok "P03-AC-4: (SCHED_RAMP=1) turn.py took was called for R1" pcalled "took R1"
qok "P03-AC-4: (SCHED_RAMP=1) a failing turn.py took starts nothing" test "$(qn)" = 0
qok "P03-AC-4: (SCHED_RAMP=1) a failing turn.py took is logged" grep -qi 'took' "$(qlog qa)"
qok "P03-AC-4: (SCHED_RAMP=1) a failing turn.py took leaves no start record" test ! -e "$qd/state/starts.json"
qok "P03-AC-4: (SCHED_RAMP=1) its RELEASE is removed" no_release R1
qok "P03-AC-4: (SCHED_RAMP=1) a failing turn.py took keeps its waiting record with the original time (the wait does not restart)" test "$(qrec qa/node R1)" = "$rc0"
qticks 2
qok "P03-AC-4: (SCHED_RAMP=1) after a further tick the record still has the original time" test "$(qrec qa/node R1)" = "$rc0"
qstop

# -- Phase D: a failed start of the released node gives the record back (R1's worktree cannot be made: its branch is checked out elsewhere)
qsetup PD "R1:S" "B01:S"; pwrap
git -C "$qd/repos/qa" worktree add -q -b node/R1-u-R1 "$q/blocker" origin/main
now=$(date +%s); mkdir -p "$qd/state"
printf '{"time": %s, "repo": "qb", "unit": "B01"}\n' $((now - 1000)) >"$qd/state/starts.json"
qseed qa/node R1 1000; rd0=$(qrec qa/node R1)
qhold; qloop qa 1 SCHED_START_GAP=1 SCHED_STARVE=3600
qwait 8 qfirst qa
release R1
wait_until 8 grep -q 'worktree for R1 failed' "$(qlog qa)"
wait_until 6 pcalled "giveback R1"
qticks 1
qok "P03-AC-4: (SCHED_RAMP=1) the failed start is logged, nothing started" sh -c "grep -q 'worktree for R1 failed' '$(qlog qa)' && [ '$(qn)' = 0 ]"
qok "P03-AC-4: (SCHED_RAMP=1) a failed start of the released node: took R1, then giveback R1" sh -c "$(declare -f pline); q='$q'; a=\$(pline 'took R1'); b=\$(pline 'giveback R1'); [ -n \"\$a\" ] && [ -n \"\$b\" ] && [ \"\$a\" -lt \"\$b\" ]"
qok "P03-AC-4: (SCHED_RAMP=1) the previous start record is back (qb/B01 at its old time)" test "$(srec)" = "qb/B01@$((now - 1000))"
qok "P03-AC-4: (SCHED_RAMP=1) its RELEASE is removed" no_release R1
qok "P03-AC-4: (SCHED_RAMP=1) a failed start keeps its waiting record with the original time (the wait does not restart)" test "$(qrec qa/node R1)" = "$rd0"
qticks 2
qok "P03-AC-4: (SCHED_RAMP=1) after a further tick the record still has the original time" test "$(qrec qa/node R1)" = "$rd0"
git -C "$qd/repos/qa" worktree remove --force "$q/blocker"; git -C "$qd/repos/qa" branch -q -D node/R1-u-R1
qstop
# -- Phase E: after a failing `turn.py took`, a second released node does not start in that tick (the first took fails once)
qsetup PE "R1:S R2:S" "B01:S"; pwrap
sed -i 's|^if a and a\[0\] == "took" and os.path.exists(q + "/took.fail"):|if a and a[0] == "took" and os.path.exists(q + "/took.fail"):\n    os.remove(q + "/took.fail")|' "$qnb/scheduler/turn.py"
: >"$q/took.fail"
qhold; qloop qa 1 SCHED_START_GAP=1 SCHED_STARVE=3600
qwait 8 qfirst qa
mkdir -p "$qd/state/qa/node/R1" "$qd/state/qa/node/R2"; d_=$(date -u +%FT%TZ); echo "$d_" >"$qd/state/qa/node/R1/RELEASE"; echo "$d_" >"$qd/state/qa/node/R2/RELEASE"
wait_until 8 grep -q '^took' "$q/turn.calls"
qticks 2
pafter() { awk '/^took/ && !f { f = 1; next } f { print; exit }' "$q/turn.calls"; }
qok "P03-AC-4: (SCHED_RAMP=1) a failing turn.py took is followed by no other took in that tick (a second released node does not start)" sh -c "$(declare -f pafter); q='$q'; n=\$(pafter); [ -n \"\$n\" ] && case \"\$n\" in took*) false ;; esac"
qstop


loop_end
