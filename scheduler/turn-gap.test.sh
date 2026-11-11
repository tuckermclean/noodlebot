#!/bin/sh
# Tests scheduler/turn.py (S07), part: starvation, the turn text, the gap, stopped loops, given-back starts, an ask racing a list.
#   sh scheduler/turn-gap.test.sh   (make test)
# The interface of turn.py and the helpers are in testdata/lib/turn-common.sh; the parts run at once.
set -u
src=$(cd "$(dirname "$0")" && pwd -P)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fails=0
. "$src/testdata/lib/turn-common.sh"

# starvation: past the limit first (longest wait first), just short of it not
reset
hb a "$base"
{
	echo "Tr triage - $(w 999)"
	echo "Sh fresh M $(w 999)"
	echo "St fresh L $(w 3000)"
	echo "Sm fresh S $(w 2000)"
	echo "Sx fresh L $(w 1001)"
} >"$tmp/u.a"
list a 1000 <"$tmp/u.a"
ask a "$base" --gap 10 --starve 1000
if [ $rc = 0 ] && [ "$key" = St ]; then pass "S07-AC-2 starved units go first, the longest waiting first (L at 3000 s before S at 2000 s)"; else fail "S07-AC-2 starved first: rc=$rc $out"; fi
case $out in *tarv*) pass "S07-AC-2 the turn text says the starvation limit put the unit first" ;; *) fail "S07-AC-2 starved text: $out" ;; esac
reset; hb a "$base"
{ echo "Tr triage - $(w 999)"; echo "Sh fresh M $(w 999)"; echo "Sx fresh L $(w 1001)"; } >"$tmp/u.a"
list a 1000 <"$tmp/u.a"; ask a "$base" --gap 10 --starve 1000
[ $rc = 0 ] && [ "$key" = Sx ] && pass "S07-AC-2 a unit at 1001 s with a limit of 1000 s starves" || fail "S07-AC-2 just past the limit: rc=$rc $out"
reset; hb a "$base"
{ echo "Tr triage - $(w 999)"; echo "Sh fresh M $(w 999)"; echo "Sx fresh L $(w 999)"; } >"$tmp/u.a"
list a 1000 <"$tmp/u.a"; ask a "$base" --gap 10 --starve 1000
[ $rc = 0 ] && [ "$key" = Tr ] && pass "S07-AC-2 a unit at 999 s with a limit of 1000 s does not starve" || fail "S07-AC-2 just short of the limit: rc=$rc $out"
# the starvation limit across repositories, and from env / by default
reset; hb a "$base"; hb b "$base"
echo "A1 triage - $(w 50)" | list a 1000
echo "B1 fresh L $(w 1500)" | list b 1000
ask a "$base" --gap 10 --starve 1000
[ $rc = 0 ] && [ -z "$key" ] && pass "S07-AC-2 another loop's starved unit holds this loop's turn" || fail "S07-AC-2 starved in another repo: rc=$rc $out"
ask b "$base" --gap 10 --starve 1000
[ $rc = 0 ] && [ "$key" = B1 ] && pass "S07-AC-2 and it is the one that gets the turn" || fail "S07-AC-2 starved owner: rc=$rc $out"
reset; hb a "$base"
{ echo "T triage - $(w 100)"; echo "L fresh L $(w 21601)"; } | list a 1000
ask a "$base" --gap 10; k1=$key r1=$rc
reset; hb a "$base"
{ echo "T triage - $(w 100)"; echo "L fresh L $(w 21599)"; } | list a 1000
ask a "$base" --gap 10; k2=$key r2=$rc
[ $r1 = 0 ] && [ $r2 = 0 ] && [ "$k1" = L ] && [ "$k2" = T ] && pass "S07-AC-2 the default starvation limit is 21600 s" || fail "S07-AC-2 default starve: '$k1' '$k2'"
reset; hb a "$base"
{ echo "T triage - $(w 100)"; echo "L fresh L $(w 600)"; } | list a 1000
out=$(SCHED_STARVE=500 T ask --root "$d" --repo a --now "$base" --gap 10 2>&1); rc=$?
[ $rc = 0 ] && [ "$(printf '%s' "$out" | cut -f1)" = L ] && pass "S07-AC-2 SCHED_STARVE in the environment is read" || fail "S07-AC-2 SCHED_STARVE env: rc=$rc $out"

# --- the turn text
reset; hb a "$base"; hb b "$base"
echo "S1 fresh S $(w 7800)" | list a 1000
echo "B1 fresh L $(w 9000)" | list b 1000
ask a "$base" --gap 10
case $out in S1"	"turn:\ S,\ waited\ 2h10m*ahead\ of\ b/B1*) pass "S07-AC-2 the turn text names the Size, the wait and the unit it went ahead of ($out)" ;; *) fail "S07-AC-2 turn text: rc=$rc [$out]" ;; esac
# the text is for the first unit of the merged order; B1 waited longer but is a L node, so S1 goes ahead
reset; hb a "$base"; hb b "$base"
echo "T1 triage - $(w 100)" | list a 1000
{ for i in 1 2 3 4; do echo "B$i fresh L $((base - 5000 - i))"; done; } | list b 1000
ask a "$base" --gap 10
case $out in *"ahead of "*"+1 more"*) pass "S07-AC-2 at most three units named, then +N more ($out)" ;; *) fail "S07-AC-2 +N more: rc=$rc [$out]" ;; esac

# --- S07-AC-1: the gap
reset; hb a "$base"; hb b "$base"; hb c "$base"
{ echo "A1 triage - $(w 50)"; echo "A2 triage - $(w 40)"; } | list a 60
echo "B1 fresh L $(w 10)" | list b 120
echo "C1 triage - $(w 900)" | list c 1000
hb c $((base - 3001))   # c's heartbeat is older than three of its ticks: stale, so its tick 1000 is not counted
ask a "$base"
[ $rc = 0 ] && [ "$key" = A1 ] && pass "S07-AC-1 the first start of the machine is given a turn at once" || fail "S07-AC-1 first turn: rc=$rc $out"
echo "A2 triage - $(w 40)" | list a 60
ask a $((base + 119))
[ $rc = 0 ] && [ -z "$key" ] && pass "S07-AC-1 by default the gap is the largest tick among the live loops: no turn after 119 s of 120" || fail "S07-AC-1 default gap before: rc=$rc $out"
ask b $((base + 119))
[ $rc = 0 ] && [ -z "$key" ] && pass "S07-AC-1 no turn for any loop inside the gap" || fail "S07-AC-1 default gap before (b): rc=$rc $out"
ask a $((base + 120))
[ $rc = 0 ] && [ "$key" = A2 ] && pass "S07-AC-1 at the gap (120 s, the stale loop's tick 1000 not counted) the next turn is given" || fail "S07-AC-1 default gap at: rc=$rc $out"

reset; hb a "$base"; hb b "$base"
{ echo "A1 triage - $(w 50)"; echo "A2 triage - $(w 40)"; } | list a 60
echo "B1 fresh L $(w 10)" | list b 120
ask a "$base" --gap 30
echo "A2 triage - $(w 40)" | list a 60
ask a $((base + 29)) --gap 30; r1=$rc k1=$key
ask a $((base + 30)) --gap 30; r2=$rc k2=$key
[ $r1 = 0 ] && [ -z "$k1" ] && [ $r2 = 0 ] && [ "$k2" = A2 ] && pass "S07-AC-1 --gap 30 overrides the default: none at 29 s, a turn at 30 s" || fail "S07-AC-1 --gap: '$k1' '$k2' $r1 $r2"
echo "A3 triage - $(w 30)" | list a 60
out=$(SCHED_START_GAP=40 T ask --root "$d" --repo a --now $((base + 60)) 2>&1); rc=$?
[ $rc = 0 ] && [ -z "$out" ] && pass "S07-AC-1 SCHED_START_GAP in the environment is read (30 s after the last start of 40)" || fail "S07-AC-1 env gap before: rc=$rc $out"
out=$(SCHED_START_GAP=40 T ask --root "$d" --repo a --now $((base + 70)) 2>&1); rc=$?
[ $rc = 0 ] && [ "$(printf '%s' "$out" | cut -f1)" = A3 ] && pass "S07-AC-1 and a turn 40 s after the last start" || fail "S07-AC-1 env gap at: rc=$rc $out"

# --- S07-AC-4: a loop that stopped is left out
reset; hb a "$base"; hb b $((base - 301))
echo "A1 fresh L $(w 10)" | list a 1000
echo "B1 triage - $(w 500)" | list b 100
ask a "$base" --gap 10
[ $rc = 0 ] && [ "$key" = A1 ] && pass "S07-AC-4 a loop whose heartbeat is older than three of its ticks (301 s, tick 100) is left out" || fail "S07-AC-4 stale loop: rc=$rc $out"
reset; hb a "$base"; hb b $((base - 299))
echo "A1 fresh L $(w 10)" | list a 1000
echo "B1 triage - $(w 500)" | list b 100
ask a "$base" --gap 10
[ $rc = 0 ] && [ -z "$key" ] && pass "S07-AC-4 a loop with a heartbeat 299 s old (tick 100) is live and goes first" || fail "S07-AC-4 live loop: rc=$rc $out"
reset; hb a "$base"
echo "A1 fresh L $(w 10)" | list a 1000
echo "B1 triage - $(w 500)" | list b 100
ask a "$base" --gap 10
[ $rc = 0 ] && [ "$key" = A1 ] && pass "S07-AC-4 a loop without a heartbeat is left out" || fail "S07-AC-4 no heartbeat: rc=$rc $out"

# --- S07-AC-4: a failed start gives its turn back
reset; hb a "$base"; hb b "$base"
printf '{"time": %s, "repo": "b", "unit": "Z9"}\n' $((base - 1000)) >"$d/state/starts.json"
{ echo "A1 triage - $(w 100)"; echo "A2 triage - $(w 50)"; } | list a 1000
echo "B1 fresh S $(w 10)" | list b 1000
ask a "$base" --gap 10
[ $rc = 0 ] && [ "$key" = A1 ] && pass "S07-AC-4 (setup) the first unit gets the turn" || fail "S07-AC-4 setup: rc=$rc $out"
T giveback A1 --root "$d" --repo a --now "$base" >/dev/null 2>&1; rc=$?
if [ $rc = 0 ] && [ "$(sj "$d/state/starts.json" "d['time']")" = $((base - 1000)) ] && [ "$(sj "$d/state/starts.json" "d['unit']")" = Z9 ]; then pass "S07-AC-4 the give-back restores the previous start record"; else fail "S07-AC-4 restore: rc=$rc $(cat "$d/state/starts.json" 2>&1)"; fi
ask a "$base" --gap 10
[ $rc = 0 ] && [ "$key" = A2 ] && pass "S07-AC-4 the same tick, the next unit in the order starts; the failed unit is not asked again" || fail "S07-AC-4 next unit: rc=$rc $out"
T giveback A2 --root "$d" --repo a --now "$base" >/dev/null 2>&1
ask a "$base" --gap 10
[ $rc = 0 ] && [ -z "$key" ] && pass "S07-AC-4 with both its units given back this loop has no turn" || fail "S07-AC-4 both given back: rc=$rc $out"
ask b "$base" --gap 10
[ $rc = 0 ] && [ "$key" = B1 ] && pass "S07-AC-4 and the other loop's unit behind them gets the turn" || fail "S07-AC-4 other loop: rc=$rc $out"
{ echo "A1 triage - $(w 100)"; echo "A2 triage - $(w 50)"; } | list a 1000
ask a $((base + 10)) --gap 10
[ $rc = 0 ] && [ "$key" = A1 ] && pass "S07-AC-4 at the loop's next list the failed unit waits again, in its place" || fail "S07-AC-4 next tick: rc=$rc $out"

reset; hb a "$base"; hb b "$base"
multi=0 bad=0
i=0
while [ $i -lt 20 ]; do
	rm -f "$d/state/starts.json" "$tmp/oa" "$tmp/ob"
	{ echo "A1 fresh L $(w 100)"; echo "A2 fresh L $(w 90)"; } | list a 1000
	echo "B1 fresh L $(w 95)" | list b 1000
	( echo "A3 triage - $(w 10)" | T list --root "$d" --repo b --tick 1000 --now "$base" >/dev/null 2>&1 ) &
	( T ask --root "$d" --repo a --now "$base" --gap 100 >"$tmp/oa" 2>&1 ) &
	( T ask --root "$d" --repo b --now "$base" --gap 100 >"$tmp/ob" 2>&1 ) &
	wait
	n=0; [ -s "$tmp/oa" ] && n=$((n + 1)); [ -s "$tmp/ob" ] && n=$((n + 1))
	[ $n -gt 1 ] && multi=$((multi + 1))
	set --
	for f in "$d/state/starts.json" "$d/state/a/waiting.json" "$d/state/b/waiting.json"; do
		[ -e "$f" ] || continue   # the list may reach b's ask first: then nobody is granted
		set -- "$@" "$f"
	done
	bad=$((bad + $(nbad "$@")))
	i=$((i + 1))
done
[ $multi = 0 ] && [ $bad = 0 ] && pass "S07-AC-3 an ask racing a list that changes the head unit: never two grants, files well-formed" || fail "S07-AC-3 ask racing list: $multi double grants, $bad malformed files"

echo

echo
if [ $fails = 0 ]; then echo "all turn tests passed"; else echo "$fails turn test(s) failed"; exit 1; fi
