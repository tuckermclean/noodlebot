#!/bin/sh
# Tests scheduler/turn.py (S13), part: the machine budget SCHED_MACHINE_MAX of `ask` and `took`.
#   sh scheduler/turn-budget.test.sh   (make test)
# Interface of turn.py fixed by this test (the implementer builds against it; loop.sh uses it):
#   SCHED_MACHINE_MAX   read by turn.py from the environment (as SCHED_START_GAP is). Unset, empty, 0 or not a positive
#                       number: no machine budget, behaviour exactly as before.
#   The count           every DATA/state/*/{node,issue,pr,adopt}/*/session.pid whose pid is a live process whose
#                       /proc/<pid>/cmdline contains run-session.sh (any repository, loop live or not); plus the last
#                       granted start (starts.json) while it is within the gap (now - time < gap) and its unit's state
#                       folder has no session.pid yet (key -> folder: ID -> node/ID, #N -> issue/N, PR#N -> pr/N,
#                       adopt-K -> adopt/K, under state/<repo of the start>/). A pid file of a dead process, or of a live
#                       process whose command line lacks run-session.sh, is not counted; nor is any other folder (pickup).
#                       A granted unit whose session.pid exists is counted once (as a session), not twice.
#                       (fix round) Every start recorded within the gap counts as pending, the last and its prev chain, each
#                       by the same rule; N prints as an integer when it is integral (1000000, not 1e+06).
#   ask      with the budget full (count >= MAX): prints nothing (stdout and stderr both empty), records nothing
#            (starts.json unchanged), exit 0; the order and the waits are unchanged.
#   took KEY with the budget full: exit code 3, one line on stderr naming the machine budget, "<n> of <N> sessions
#            running on the machine" within it; starts.json and waiting.json unchanged.
#   count    turn.py count --root DATA --repo NAME: read-only; prints "<n> of <N> sessions running on the machine"
#            (N = SCHED_MACHINE_MAX, or 0 when it is unset), exit 0, writes nothing.
#   (own resume)    a `resumed` unit first in the merged order whose own state folder (key -> folder as above, under
#                       state/<asking repo>/) holds one of the live sessions does not count that session against its own
#                       turn: with MAX=N and N live sessions `ask` grants it. Only that: any other unit, a `resumed` unit
#                       whose own folder has no live session (a same-named folder of another repository is not its own),
#                       is held as before, and the other sessions idle at the limit still hold a new unit.
# The helpers are in testdata/lib/turn-common.sh; the live "sessions" are scratch processes of $tmp/S13/run-session.sh.
set -u
src=$(cd "$(dirname "$0")" && pwd -P)
tmp=$(mktemp -d) && [ -d "$tmp" ] || exit 1
. "$src/testdata/lib/kill-own.sh"
mkdir -p "$tmp/S13"
cleanup() { kill_own "$tmp/S13" "$tmp"/S13/pid.*; rm -rf "$tmp"; }
trap cleanup EXIT
fails=0
. "$src/testdata/lib/turn-common.sh"
unset SCHED_MACHINE_MAX SCHED_START_GAP SCHED_STARVE

# the scripts of the scratch processes: one is a session (run-session.sh), one is not
for f in run-session.sh other.sh; do
	printf 'while :; do sleep 1; done\n' >"$tmp/S13/$f"
done
# spawn <script>: starts it, sets sp to its pid once its command line names the script
spawn() {
	sh "$tmp/S13/$1" &
	sp=$!
	echo "$sp" >"$tmp/S13/pid.$sp"
	i=0
	while [ $i -lt 100 ]; do
		grep -qF "$1" "/proc/$sp/cmdline" 2>/dev/null && return 0
		sleep 0.05; i=$((i + 1))
	done
}
# stop <pid>: ends the process and waits until it is gone
stop() {
	kill_own "$tmp/S13" "$tmp/S13/pid.$1"
	wait "$1" 2>/dev/null
	i=0
	while [ $i -lt 100 ] && [ -n "$(cat "/proc/$1/cmdline" 2>/dev/null)" ]; do sleep 0.05; i=$((i + 1)); done
}
# pidfile <repo> <kind> <name> <pid>
pidfile() { mkdir -p "$d/state/$1/$2/$3"; echo "$4" >"$d/state/$1/$2/$3/session.pid"; }
max() { if [ -z "$1" ]; then unset SCHED_MACHINE_MAX; else SCHED_MACHINE_MAX=$1; export SCHED_MACHINE_MAX; fi; }
took() { r=$1 n=$2 k=$3; shift 3; out=$(T took --root "$d" --repo "$r" --now "$n" "$@" "$k" 2>&1); rc=$?; }
snap() { { cat "$d/state/starts.json" 2>/dev/null || echo none; cat "$d"/state/*/waiting.json 2>/dev/null; } | cksum; }
rec() { sj "$d/state/starts.json" "d['repo']+'/'+d['unit']+'@'+str(int(d['time']))"; }
cnt() { out=$(T count --root "$d" --repo "$1" 2>&1); rc=$?; }
G="--gap 10 --starve 100000"

spawn run-session.sh; s1=$sp
spawn run-session.sh; s2=$sp
spawn other.sh; o1=$sp
spawn run-session.sh; s3=$sp
stop "$s3"; dead=$s3

# --- two live sessions in two repositories (and a third repository with no loop) fill MAX=2
reset; max 2; hb a "$base"; hb b "$base"
echo "A2 fresh S $(w 100)" | list a 10
echo "B2 triage - $(w 500)" | list b 10
pidfile a node A1 "$s1"; pidfile c issue 7 "$s2"
before=$(snap)
ask a "$base" $G; ra=$rc oa=$out
ask b "$base" $G
if [ $ra = 0 ] && [ -z "$oa" ] && [ $rc = 0 ] && [ -z "$out" ] && [ "$(snap)" = "$before" ] && [ ! -e "$d/state/starts.json" ]; then pass "S13-AC-1 with MAX=2 and two live sessions in two repositories ask prints nothing, records nothing, exit 0"; else fail "full budget ask: rc=$ra/$rc out='$oa'/'$out' starts=$(rec)"; fi
# --- one of them gone: the first unit of the merged order gets the turn
stop "$s2"
ask a "$base" $G
ra=$rc oa=$out
ask b "$base" $G
if [ $ra = 0 ] && [ -z "$oa" ] && [ $rc = 0 ] && [ "$key" = B2 ] && [ "$(rec)" = "b/B2@$base" ]; then pass "S13-AC-1 with one session gone the next ask grants the first unit of the merged order (b/B2), the other loop none"; else fail "after one session ended: a='$oa' rc=$ra / b rc=$rc out='$out' rec=$(rec)"; fi
spawn run-session.sh; s2=$sp

# --- every kind of folder counts one live session; pickup and other folders do not
for kind in node issue pr adopt; do
	reset; max 1; hb a "$base"; echo "A2 fresh S $(w 100)" | list a 10
	pidfile b "$kind" X9 "$s1"
	ask a "$base" $G
	if [ $rc = 0 ] && [ -z "$out" ] && [ ! -e "$d/state/starts.json" ]; then pass "S13-AC-1 a live session in $kind/ counts: MAX=1 grants no turn"; else fail "session in $kind/: rc=$rc out='$out'"; fi
done
reset; max 1; hb a "$base"; echo "A2 fresh S $(w 100)" | list a 10
pidfile b pickup P1 "$s1"; pidfile b other X "$s2"
ask a "$base" $G
if [ $rc = 0 ] && [ "$key" = A2 ]; then pass "S13-AC-1 a live pid in pickup/ or another folder is not counted"; else fail "pickup folder counted: rc=$rc out='$out'"; fi

# --- a dead pid and a live non-session process are not counted
reset; max 1; hb a "$base"; echo "A2 fresh S $(w 100)" | list a 10
pidfile a node A1 "$dead"; pidfile b node B1 "$o1"
ask a "$base" $G
if [ $rc = 0 ] && [ "$key" = A2 ]; then pass "S13-AC-1 with a dead pid file and a live non-session process, MAX=1 still grants a turn"; else fail "dead/non-session counted: rc=$rc out='$out'"; fi
reset; max 1; hb a "$base"
pidfile a node A1 "$dead"; pidfile b node B1 "$o1"
cnt a
if [ $rc = 0 ] && [ "$out" = "0 of 1 sessions running on the machine" ]; then pass "S13-AC-1 count: the dead pid and the non-session are not in it"; else fail "count with dead/non-session: rc=$rc out='$out'"; fi

# --- took with the budget full refuses and records nothing
reset; max 1; hb a "$base"; hb b "$base"
echo "A2 fresh S $(w 100)" | list a 10
pidfile b node B1 "$s1"
before=$(snap)
took a "$base" A1
if [ $rc = 3 ] && [ "$(printf '%s\n' "$out" | wc -l)" = 1 ] && printf '%s' "$out" | grep -qi 'machine' && printf '%s' "$out" | grep -qF '1 of 1 sessions running on the machine' && [ "$(snap)" = "$before" ] && [ ! -e "$d/state/starts.json" ]; then pass "S13-AC-1 took with the budget full: exit 3, one line naming the machine budget, nothing recorded"; else fail "took with full budget: rc=$rc out='$out'"; fi
stop "$s1"; spawn run-session.sh; s1=$sp
took a "$base" A1
if [ $rc = 0 ] && [ "$(rec)" = "a/A1@$base" ]; then pass "S13-AC-1 took records when the session of the full budget is gone"; else fail "took after the session ended: rc=$rc out='$out'"; fi

# --- concurrent asks from two loops, MAX=1, no session: one turn
reset; max 1; hb a "$base"; hb b "$base"
echo "A1 triage - $(w 900)" | list a 10
echo "B1 triage - $(w 100)" | list b 10
cp1= n=0
for r in a b a b; do
	n=$((n + 1))
	T ask --root "$d" --repo "$r" --now "$base" $G >"$tmp/c.$n" 2>&1 &
	cp1="$cp1 $!"
done
wait $cp1
lines=$(cat "$tmp"/c.* | grep -c .)
if [ "$lines" = 1 ] && [ "$(nbad "$d/state/starts.json")" = 0 ] && [ "$(rec)" = "a/A1@$base" ]; then pass "S13-AC-1 concurrent asks from two loops with MAX=1 and no session grant one turn"; else fail "concurrent asks: $lines grants, rec=$(rec)"; fi
rm -f "$tmp"/c.*
# --- a second ask right after the grant, before the session's pid file exists, grants none
ask a $((base + 1)) $G
r1=$rc k1=$key
ask b $((base + 1)) $G
if [ $r1 = 0 ] && [ -z "$k1" ] && [ $rc = 0 ] && [ -z "$key" ] && [ "$(rec)" = "a/A1@$base" ]; then pass "S13-AC-1 a second ask right after the grant, before the session.pid exists, grants none"; else fail "second ask after the grant: '$k1' / '$out'"; fi

# --- the pending grant is counted: only it can refuse a took (took ignores the gap and the order)
reset; max 1; hb a "$base"; hb b "$base"
echo "A1 triage - $(w 100)" | list a 10
ask a "$base" $G
before=$(snap)
took b $((base + 2)) B9 --gap 10
if [ "$key" = A1 ] && [ $rc = 3 ] && printf '%s' "$out" | grep -qF '1 of 1 sessions running on the machine' && [ "$(snap)" = "$before" ]; then pass "S13-AC-1 a took right after a grant, within the gap, before the session.pid exists, is refused (the grant counts)"; else fail "took after a grant: rc=$rc out='$out'"; fi
max 2
took b $((base + 2)) B9 --gap 10
if [ $rc = 0 ] && [ "$(rec)" = "b/B9@$((base + 2))" ]; then pass "S13-AC-1 the same took with MAX=2 goes through (the grant counts once)"; else fail "took with MAX=2 after a grant: rc=$rc out='$out'"; fi
# the key of a triage unit is a pending grant too (#N -> issue/N), and its pid file ends it as a grant
reset; max 1; hb a "$base"
echo "#7 triage - $(w 100)" | list a 10
ask a "$base" $G
took b $((base + 2)) B9 --gap 10
if [ "$key" = '#7' ] && [ $rc = 3 ]; then pass "S13-AC-1 a granted #7 counts as running until its issue/7/session.pid appears"; else fail "took after grant of #7: key='$key' rc=$rc out='$out'"; fi
# --- after the gap the pending grant no longer counts
reset; max 1; hb a "$base"
echo "A1 triage - $(w 100)" | list a 10
ask a "$base" $G
ask a $((base + 10)) $G
if [ $rc = 0 ] && [ "$key" = A1 ] && [ "$(rec)" = "a/A1@$((base + 10))" ]; then pass "S13-AC-1 a grant whose session never started stops counting when the gap has passed"; else fail "ask a gap after a pending grant: rc=$rc out='$out'"; fi

# --- the granted unit's live session.pid is one session, not two
reset; max 2; hb a "$base"; hb b "$base"
echo "A1 triage - $(w 100)" | list a 10
ask a "$base" $G
pidfile a node A1 "$s1"
took b $((base + 2)) B9 --gap 10
if [ $rc = 0 ] && [ "$(rec)" = "b/B9@$((base + 2))" ]; then pass "S13-AC-1 a granted unit with a live session.pid counts once: took with MAX=2 goes through"; else fail "double count: rc=$rc out='$out'"; fi
reset; max 1; hb a "$base"; hb b "$base"
echo "A1 triage - $(w 100)" | list a 10
ask a "$base" $G
pidfile a node A1 "$s1"
took b $((base + 2)) B9 --gap 10
if [ $rc = 3 ] && printf '%s' "$out" | grep -qF '1 of 1 sessions running on the machine'; then pass "S13-AC-1 the granted unit's live session is counted: took with MAX=1 refused, '1 of 1'"; else fail "took with the session of the grant: rc=$rc out='$out'"; fi
# a pid file of the granted unit whose process is dead: neither a session nor a pending grant
reset; max 1; hb a "$base"; hb b "$base"
echo "A1 triage - $(w 100)" | list a 10
ask a "$base" $G
pidfile a node A1 "$dead"
took b $((base + 2)) B9 --gap 10
if [ $rc = 0 ]; then pass "S13-AC-1 a granted unit whose session.pid names a dead process counts nothing"; else fail "dead pid of the granted unit counted: rc=$rc out='$out'"; fi

# --- count: read-only, "<n> of <N> sessions running on the machine"
reset; max 2; hb a "$base"
echo "A1 triage - $(w 100)" | list a 10
pidfile a node A1 "$s1"; pidfile b pr 3 "$s2"; pidfile b node B1 "$o1"
before=$(snap)
cnt a
if [ $rc = 0 ] && [ "$out" = "2 of 2 sessions running on the machine" ] && [ "$(snap)" = "$before" ] && [ ! -e "$d/state/starts.json" ]; then pass "S13-AC-1 count prints '2 of 2 sessions running on the machine' and writes nothing"; else fail "count: rc=$rc out='$out'"; fi
max 5; cnt a
if [ $rc = 0 ] && [ "$out" = "2 of 5 sessions running on the machine" ]; then pass "S13-AC-1 count names N = SCHED_MACHINE_MAX"; else fail "count with MAX=5: rc=$rc out='$out'"; fi
max ""; cnt a
if [ $rc = 0 ] && [ "$out" = "2 of 0 sessions running on the machine" ]; then pass "S13-AC-1 count with SCHED_MACHINE_MAX unset: N is 0"; else fail "count unset: rc=$rc out='$out'"; fi
# a grant whose session has not started (real time here: count takes no --now) is in the count
reset; max 3; hb a "$(date +%s)"; echo "A1 triage - $(w 100)" | list a 10
ask a "$(date +%s)" --gap 1000 --starve 100000
cnt a
if [ "$key" = A1 ] && [ $rc = 0 ] && [ "$out" = "1 of 3 sessions running on the machine" ]; then pass "S13-AC-1 count includes a granted turn whose session has not started"; else fail "count after a grant: key='$key' rc=$rc out='$out'"; fi

# --- unset, empty, 0, not a positive number: ask and took as before, live sessions notwithstanding
for v in unset empty 0 -1 abc; do
	reset; case $v in unset) max "" ;; empty) SCHED_MACHINE_MAX=; export SCHED_MACHINE_MAX ;; *) max "$v" ;; esac
	hb a "$base"; echo "A2 fresh S $(w 100)" | list a 10
	pidfile a node A1 "$s1"; pidfile b node B1 "$s2"; pidfile c issue 4 "$o1"
	ask a "$base" $G
	if [ $rc = 0 ] && [ "$key" = A2 ] && [ "$(rec)" = "a/A2@$base" ]; then pass "S13-AC-1 SCHED_MACHINE_MAX $v: ask grants a turn despite live sessions"; else fail "ask with MAX $v: rc=$rc out='$out'"; fi
	took b $((base + 1)) B9 --gap 10
	if [ $rc = 0 ] && [ "$(rec)" = "b/B9@$((base + 1))" ]; then pass "S13-AC-1 SCHED_MACHINE_MAX $v: took records despite live sessions"; else fail "took with MAX $v: rc=$rc out='$out'"; fi
done
unset SCHED_MACHINE_MAX

# --- (fix round) a granted start whose session has started is counted once: the key -> state folder of each kind
# (ID -> node/ID, #N -> issue/N, PR#N -> pr/N, adopt-K -> adopt/K); a wrong folder would count it twice (MAX=2)
for kv in '#7 triage issue 7' 'PR#5 update pr 5' 'adopt-k triage adopt k'; do
	set -- $kv; gk=$1 gkind=$2 gdir=$3 gname=$4
	reset; max 2; hb a "$base"; hb b "$base"
	echo "$gk $gkind - $(w 100)" | list a 10
	ask a "$base" $G
	pidfile a "$gdir" "$gname" "$s1"
	took b $((base + 2)) B9 --gap 10
	if [ "$key" = "$gk" ] && [ $rc = 0 ] && [ "$(rec)" = "b/B9@$((base + 2))" ]; then pass "S13-AC-1 a granted $gk with a live $gdir/$gname/session.pid counts once: took with MAX=2 goes through"; else fail "double count of $gk: key='$key' rc=$rc out='$out'"; fi
done

# --- (fix round) pending grants are not only the last start: the count includes every start recorded within the gap, the last and its prev
reset; max 2; hb a "$base"; hb b "$base"
echo "X1 triage - $(w 100)" | list a 10
ask a "$base" $G
kx=$key
took b $((base + 1)) A9 --gap 10
r1=$rc
before=$(snap)
took b $((base + 2)) B9 --gap 10
if [ "$kx" = X1 ] && [ $r1 = 0 ] && [ $rc = 3 ] && printf '%s' "$out" | grep -qF '2 of 2 sessions running on the machine' && [ "$(snap)" = "$before" ]; then pass "S13-AC-1 a granted ask and a took within the gap, none with a session.pid, are two: the next took with MAX=2 is refused"; else fail "pending grants: ask='$kx' took1 rc=$r1, took2 rc=$rc out='$out'"; fi
max 3
took b $((base + 2)) B9 --gap 10
if [ $rc = 0 ] && [ "$(rec)" = "b/B9@$((base + 2))" ]; then pass "S13-AC-1 the same took with MAX=3 goes through (two pending grants)"; else fail "took with MAX=3 after two grants: rc=$rc out='$out'"; fi

# --- (fix round) an integral budget prints as an integer
reset; max 1000000; hb a "$base"
cnt a
if [ $rc = 0 ] && [ "$out" = "0 of 1000000 sessions running on the machine" ]; then pass "S13-AC-1 count with SCHED_MACHINE_MAX=1000000 prints the integer, not 1e+06"; else fail "count with MAX=1000000: rc=$rc out='$out'"; fi
unset SCHED_MACHINE_MAX

# --- (review round) pending grants three deep: the prev chain is kept through each record, not only one level
reset; max 3; hb a "$base"; hb b "$base"
echo "X1 triage - $(w 100)" | list a 10
ask a "$base" $G
kx=$key
took b $((base + 1)) A9 --gap 10
r1=$rc
took b $((base + 2)) B9 --gap 10
r2=$rc
before=$(snap)
took b $((base + 3)) C9 --gap 10
if [ "$kx" = X1 ] && [ $r1 = 0 ] && [ $r2 = 0 ] && [ $rc = 3 ] && printf '%s' "$out" | grep -qF '3 of 3 sessions running on the machine' && [ "$(snap)" = "$before" ]; then pass "S13-AC-1 three pending grants (an ask and two tooks) within the gap count three: the next took with MAX=3 is refused, nothing recorded"; else fail "three deep: ask='$kx' took rc=$r1/$r2/$rc out='$out'"; fi

# --- (review round) a fractional budget compares as a number: 1 < 1.5 grants, 2 < 1.5 does not
reset; max 1.5; hb a "$base"; echo "A2 fresh S $(w 100)" | list a 10
pidfile b node B1 "$s1"
cnt a
c1=$out rc1=$rc
ask a "$base" $G
if [ $rc1 = 0 ] && [ "$c1" = "1 of 1.5 sessions running on the machine" ] && [ $rc = 0 ] && [ "$key" = A2 ]; then pass "S13-AC-1 SCHED_MACHINE_MAX=1.5 with one live session: count prints '1 of 1.5' and ask grants a turn"; else fail "MAX=1.5, one session: count rc=$rc1 out='$c1'; ask rc=$rc key='$key' out='$out'"; fi
reset; max 1.5; hb a "$base"; echo "A2 fresh S $(w 100)" | list a 10
pidfile b node B1 "$s1"; pidfile c issue 7 "$s2"
ask a "$base" $G
if [ $rc = 0 ] && [ -z "$out" ] && [ ! -e "$d/state/starts.json" ]; then pass "S13-AC-1 SCHED_MACHINE_MAX=1.5 with two live sessions: ask grants no turn"; else fail "MAX=1.5, two sessions: rc=$rc out='$out'"; fi
unset SCHED_MACHINE_MAX

# --- (whole-node review) with no machine budget a giveback restores only the one previous start, as before: took X, A, B within the gap, give B back, then A: starts.json is gone and the next ask is granted
for m in "" 0; do
	reset; max "$m"; hb a "$base"; echo "X1 triage - $(w 100)" | list a 10
	took a "$base" X1 --gap 100
	rx=$rc
	took a $((base + 1)) A9 --gap 100
	ra=$rc
	took a $((base + 2)) B9 --gap 100
	rb=$rc
	T giveback --root "$d" --repo a --now $((base + 3)) B9 >/dev/null 2>&1
	T giveback --root "$d" --repo a --now $((base + 3)) A9 >/dev/null 2>&1
	gone=no; [ ! -e "$d/state/starts.json" ] && gone=yes
	hb a $((base + 200))
	echo "X1 triage - $(w 100)" | list a 10
	ask a $((base + 200)) --gap 100 --starve 100000
	if [ $rx = 0 ] && [ $ra = 0 ] && [ $rb = 0 ] && [ "$gone" = yes ] && [ $rc = 0 ] && [ "$key" = X1 ]; then pass "S13-AC-1 SCHED_MACHINE_MAX='${m:-unset}': took X, A, B then giveback B and A leaves no starts.json and the next ask is granted"; else fail "MAX='${m:-unset}' took rc=$rx/$ra/$rb, starts.json gone=$gone ($(cat "$d/state/starts.json" 2>/dev/null)); ask rc=$rc key='$key'"; fi
done
unset SCHED_MACHINE_MAX

# --- (own resume) a `resumed` unit whose own state folder holds one of the N live sessions is not held: its turn replaces it
for kv in 'R1 node R1' '#7 issue 7'; do
	set -- $kv; rk=$1 rkind=$2 rname=$3
	reset; max 2; hb a "$base"; hb b "$base"
	echo "$rk resumed - $(w 600)" | list a 10
	echo "B2 triage - $(w 100)" | list b 10
	pidfile a "$rkind" "$rname" "$s1"; pidfile b node B1 "$s2"
	ask a "$base" $G
	if [ $rc = 0 ] && [ "$key" = "$rk" ] && [ "$(rec)" = "a/$rk@$base" ]; then pass "S13-AC-1 MAX=2, two live sessions, one in the own $rkind/$rname folder of the resumed $rk first in the order: ask grants it"; else fail "own resume $rk: rc=$rc out='$out' rec=$(rec)"; fi
done
# the count stays at N: after that grant (its session.pid is live, counted once) a different unit's ask is still held
reset; max 2; hb a "$base"; hb b "$base"
echo "R1 resumed - $(w 600)" | list a 10
echo "B2 triage - $(w 100)" | list b 10
pidfile a node R1 "$s1"; pidfile b node B1 "$s2"
ask a "$base" $G
g1=$key
: | list a 10
ask b $((base + 10)) $G
if [ "$g1" = R1 ] && [ $rc = 0 ] && [ -z "$out" ] && [ "$(rec)" = "a/R1@$base" ]; then pass "S13-AC-1 after the resumed unit's grant a different unit's ask is still held (the count stays at N=2)"; else fail "after own-resume grant: first='$g1', b rc=$rc out='$out' rec=$(rec)"; fi

# --- N live sessions idle at the limit, each one's unit waiting as resumed, a different new unit first: it gets nothing
reset; max 2; hb a "$base"; hb b "$base"
{ echo "N1 triage - $(w 900)"; echo "R1 resumed - $(w 100)"; } | list a 10
echo "R2 resumed - $(w 100)" | list b 10
pidfile a node R1 "$s1"; pidfile b node R2 "$s2"
before=$(snap)
ask a "$base" $G; ra=$rc oa=$out
ask b "$base" $G
if [ $ra = 0 ] && [ "$(printf '%s' "$oa" | cut -f1)" = R1 ] && [ $rc = 0 ] && [ -z "$out" ] && [ "$(rec)" = "a/R1@$base" ]; then pass "S13-AC-1 N=2 sessions idle at the limit, a new triage unit first: N1 is not granted, a's ask grants R1 (its own session is live), b's ask grants nothing"; else fail "new unit first vs idle sessions: a rc=$ra out='$oa' / b rc=$rc out='$out' rec=$(rec)"; fi
reset; max 2; hb a "$base"; hb b "$base"
{ echo "F1 fresh S $(w 900)"; echo "R1 resumed - $(w 50)"; } | list a 10
echo "R2 resumed - $(w 60)" | list b 10
pidfile a node R1 "$s1"; pidfile b node R2 "$s2"
ask a "$base" --gap 10 --starve 100
if [ $rc = 0 ] && [ -z "$out" ] && [ ! -e "$d/state/starts.json" ]; then pass "S13-AC-1 N=2 idle sessions and a new fresh unit first (by the starvation limit): ask grants nothing"; else fail "new fresh unit vs idle sessions: rc=$rc out='$out' rec=$(rec)"; fi

# --- (held first) the first unit is held by the budget: the first resumed unit with its own live session takes the turn, the held unit keeps first place
# the held unit keeps first place for the next free slot: once one of the other sessions ends, N1 is granted, not another resumed unit
reset; max 2; hb a "$base"; hb b "$base"
{ echo "N1 triage - $(w 900)"; echo "R1 resumed - $(w 100)"; } | list a 10
echo "R2 resumed - $(w 100)" | list b 10
pidfile a node R1 "$s1"; pidfile b node R2 "$s2"
ask a "$base" $G; g1=$key
pidfile b node R2 "$dead"
ask b $((base + 10)) $G; rb=$rc ob=$out
ask a $((base + 10)) $G
if [ "$g1" = R1 ] && [ $rb = 0 ] && [ -z "$ob" ] && [ $rc = 0 ] && [ "$key" = N1 ] && [ "$(rec)" = "a/N1@$((base + 10))" ]; then pass "S13-AC-1 after the held-first grant of R1 and a slot freed, the next ask grants N1 (the held unit kept first place), not another resumed unit"; else fail "held unit after a slot frees: first='$g1', b rc=$rb out='$ob' / a rc=$rc out='$out' rec=$(rec)"; fi
# no new unit starts while N run: the new unit first in b's list is not granted; a's resumed own-session unit is
reset; max 2; hb a "$base"; hb b "$base"
echo "R1 resumed - $(w 100)" | list a 10
echo "N1 triage - $(w 900)" | list b 10
pidfile a node R1 "$s1"; pidfile b node B1 "$s2"
ask b "$base" $G; rb=$rc ob=$out
ask a "$base" $G; ra=$rc oa=$out k1=$key
ask b $((base + 10)) $G
if [ $rb = 0 ] && [ -z "$ob" ] && [ $ra = 0 ] && [ "$k1" = R1 ] && [ $rc = 0 ] && [ -z "$out" ] && [ "$(rec)" = "a/R1@$base" ]; then pass "S13-AC-1 a new unit first in b's list is not granted while N=2 run; a's ask grants the resumed own-session unit R1, and b's later ask still grants nothing"; else fail "new unit in b vs resumed in a: b rc=$rb out='$ob' / a rc=$ra key='$k1' / b again rc=$rc out='$out' rec=$(rec)"; fi
# starved-first variant of the F1 case: the first resumed unit with its own live session (R2 in b, waited longest of the two) takes the turn
reset; max 2; hb a "$base"; hb b "$base"
{ echo "F1 fresh S $(w 900)"; echo "R1 resumed - $(w 50)"; } | list a 10
echo "R2 resumed - $(w 60)" | list b 10
pidfile a node R1 "$s1"; pidfile b node R2 "$s2"
ask a "$base" --gap 10 --starve 100; ra=$rc oa=$out
ask b "$base" --gap 10 --starve 100
if [ $ra = 0 ] && [ -z "$oa" ] && [ $rc = 0 ] && [ "$key" = R2 ] && [ "$(rec)" = "b/R2@$base" ]; then pass "S13-AC-1 N=2 idle sessions and a starved fresh unit first: b's ask grants R2 (the first resumed unit with its own live session), a's grants nothing"; else fail "starved first, held: a rc=$ra out='$oa' / b rc=$rc out='$out' rec=$(rec)"; fi
# a resumed unit without a live session of its own, ahead of one that has: the turn goes to the one that has
reset; max 2; hb a "$base"; hb b "$base"
{ echo "N1 triage - $(w 900)"; echo "R1 resumed - $(w 500)"; echo "R2 resumed - $(w 100)"; } | list a 10
pidfile a node R1 "$dead"; pidfile a node R2 "$s1"; pidfile b node B1 "$s2"
ask a "$base" $G
if [ $rc = 0 ] && [ "$key" = R2 ] && [ "$(rec)" = "a/R2@$base" ]; then pass "S13-AC-1 a resumed unit without a live session of its own ahead of one with: the turn goes to the one with (R2), not to R1"; else fail "resumed without own session ahead: rc=$rc out='$out' rec=$(rec)"; fi
# two loops, each with a resumed own-session unit behind the held unit: after the first grant and past the gap the second gets its turn
reset; max 2; hb a "$base"; hb b "$base"
{ echo "N1 triage - $(w 900)"; echo "R1 resumed - $(w 100)"; } | list a 10
echo "R2 resumed - $(w 50)" | list b 10
pidfile a node R1 "$s1"; pidfile b node R2 "$s2"
ask b "$base" $G; rb=$rc ob=$out
ask a "$base" $G; g1=$key
{ echo "N1 triage - $(w 900)"; } | list a 10
ask a $((base + 10)) $G; ra=$rc oa=$out
ask b $((base + 10)) $G
if [ $rb = 0 ] && [ -z "$ob" ] && [ "$g1" = R1 ] && [ $ra = 0 ] && [ -z "$oa" ] && [ $rc = 0 ] && [ "$key" = R2 ] && [ "$(rec)" = "b/R2@$((base + 10))" ]; then pass "S13-AC-1 two loops with a resumed own-session unit each behind the held N1: R1 first, then past the gap R2 (b), a's ask grants nothing, N1 still held"; else fail "two resumed behind a held unit: b rc=$rb out='$ob' / first='$g1' / a rc=$ra out='$oa' / b rc=$rc out='$out' rec=$(rec)"; fi

# --- only its own session is excused: a resumed unit with no live session of its own is held at N
reset; max 2; hb a "$base"; hb b "$base"
echo "R1 resumed - $(w 600)" | list a 10
pidfile a node R1 "$dead"; pidfile b node B1 "$s1"; pidfile c issue 7 "$s2"
ask a "$base" $G
if [ $rc = 0 ] && [ -z "$out" ] && [ ! -e "$d/state/starts.json" ]; then pass "S13-AC-1 a resumed unit whose own session.pid names a dead process is held at N=2"; else fail "resumed, own pid dead: rc=$rc out='$out'"; fi
reset; max 2; hb a "$base"
echo "R1 resumed - $(w 600)" | list a 10
pidfile b node B1 "$s1"; pidfile c issue 7 "$s2"
ask a "$base" $G
if [ $rc = 0 ] && [ -z "$out" ] && [ ! -e "$d/state/starts.json" ]; then pass "S13-AC-1 a resumed unit with no session folder of its own is held at N=2"; else fail "resumed, no own folder: rc=$rc out='$out'"; fi
reset; max 2; hb a "$base"
echo "R1 resumed - $(w 600)" | list a 10
pidfile b node R1 "$s1"; pidfile c issue 7 "$s2"
ask a "$base" $G
if [ $rc = 0 ] && [ -z "$out" ] && [ ! -e "$d/state/starts.json" ]; then pass "S13-AC-1 a live session in a same-named folder of another repository is not the resumed unit's own: held"; else fail "resumed, same name in another repo: rc=$rc out='$out'"; fi
reset; max 2; hb a "$base"
echo "R1 resumed - $(w 600)" | list a 10
pidfile a node R1 "$o1"; pidfile b node B1 "$s1"; pidfile c issue 7 "$s2"
ask a "$base" $G
if [ $rc = 0 ] && [ -z "$out" ] && [ ! -e "$d/state/starts.json" ]; then pass "S13-AC-1 a resumed unit whose own folder holds a live non-session process is held at N=2"; else fail "resumed, own pid not a session: rc=$rc out='$out'"; fi
# only for its own resume: the same live own session of a unit that is not resumed (triage, fresh) is no excuse
for kind in triage fresh; do
	reset; max 2; hb a "$base"
	echo "R1 $kind S $(w 600)" | list a 10
	pidfile a node R1 "$s1"; pidfile b node B1 "$s2"
	ask a "$base" $G
	if [ $rc = 0 ] && [ -z "$out" ] && [ ! -e "$d/state/starts.json" ]; then pass "S13-AC-1 a $kind unit with a live session in its own folder is held at N=2 (only a resumed unit is excused)"; else fail "$kind unit with own session: rc=$rc out='$out'"; fi
done
unset SCHED_MACHINE_MAX

# --- the resumed unit's own session is left out of the count, not the whole budget: own + two others = three, MAX=2 holds it
spawn run-session.sh; s4=$sp
reset; max 2; hb a "$base"; hb b "$base"
echo "R1 resumed - $(w 600)" | list a 10
pidfile a node R1 "$s1"; pidfile b node B1 "$s2"; pidfile c issue 7 "$s4"
before=$(snap)
ask a "$base" $G
if [ $rc = 0 ] && [ -z "$out" ] && [ "$(snap)" = "$before" ] && [ ! -e "$d/state/starts.json" ]; then pass "S13-AC-1 MAX=2, a resumed unit's own live session and two other live sessions: ask grants nothing, records nothing"; else fail "resumed, own session plus two others: rc=$rc out='$out' rec=$(rec)"; fi
unset SCHED_MACHINE_MAX

[ "$fails" = 0 ] || { echo "$fails failure(s)"; exit 1; }
echo "all passed"
