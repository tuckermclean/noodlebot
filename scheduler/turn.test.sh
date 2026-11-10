#!/bin/sh
# Tests scheduler/turn.py (S07): the machine-wide queue of starts, one turn per gap, in a fixed order.
#   sh scheduler/turn.test.sh   (make test)
#
# Interface of turn.py fixed by this test (the implementer builds against it):
#   python3 -I scheduler/turn.py <list|ask|giveback> --root DATA --repo NAME [--tick SECS] [--gap SECS]
#                                [--starve SECS] [--now EPOCH] [KEY]
#   --root     $NOODLEBOT_DATA; state lives under DATA/state/. --repo is the loop's repository folder name.
#   --now      epoch seconds used as "now" (default: the real time).
#   --gap      minimum seconds between two starts, machine-wide; else env SCHED_START_GAP; else the largest
#              tick among the live loops (the asking loop included).
#   --starve   seconds; a unit that waited MORE than this goes first; else env SCHED_STARVE; else 21600.
#   list       (needs --tick) read the loop's waiting units on stdin, one per line, in the loop's own order:
#                  <key> <kind> <size> <since-epoch>     kind: triage|update|followup|resumed|fresh
#                  size: S|M|L, or - (only fresh nodes have one; - or anything else counts as L)
#              A line that does not have four fields or whose since is not a number is ignored.
#              Stores them and the tick atomically as DATA/state/NAME/waiting.json (well-formed JSON) and
#              clears this loop's give-backs (a new tick). Prints nothing, exits 0.
#   ask        reads no stdin; uses the stored lists. Under an exclusive flock on DATA/state/starts.lock it
#              gives a turn when (1) the gap has passed since the last start (>= gap) and (2) the first unit of
#              the merged order of every live loop belongs to this loop. It then records the start in
#              DATA/state/starts.json as {"time": EPOCH, "repo": NAME, "unit": KEY} (plus whatever else it
#              needs to restore the previous one) and prints one line: "<KEY>\t<text>"; no turn: prints
#              nothing. Exit 0 either way; non-zero only on an error. The text reads
#                  turn: <kind or Size>, waited <H>h<MM>m, [first by the starvation limit, ]ahead of <units>
#              where kind is the input kind (triage, update, followup, resumed) or, for a fresh node, S, M, L;
#              units that waited longer and still wait are named KEY (own repository) or NAME/KEY, up to
#              three, then "+N more"; "ahead of" is left out when there are none.
#              A loop is live when DATA/state/NAME/heartbeat (epoch) is less than three of its ticks old; a
#              loop that is stale, has no heartbeat, or has a missing or malformed waiting.json is left out.
#              A missing or malformed starts.json means "no start yet". No waiting list for this loop: no turn.
#              Order: starved (longest wait first); then triage/update/followup/resumed; then fresh S, M, L;
#              within a group the longest wait first; ties by repository name, then the loop's own order.
#   giveback KEY   the start of KEY failed: restore the starts.json that preceded the grant and leave KEY out
#              of this loop's order until its next `list`. Prints nothing, exits 0.
set -u
src=$(cd "$(dirname "$0")" && pwd -P)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
d=$tmp/d
base=1800000000
T() { python3 -I "$src/turn.py" "$@"; }
reset() { rm -rf "$d"; mkdir -p "$d/state"; }
hb() { mkdir -p "$d/state/$1"; echo "$2" >"$d/state/$1/heartbeat"; }
# list <repo> <tick> [extra args]: the units come on stdin.
list() { r=$1 t=$2; shift 2; T list --root "$d" --repo "$r" --tick "$t" --now "$base" "$@" >/dev/null 2>&1; }
# ask <repo> <now> [extra args]: sets rc, out (the whole line), key.
ask() {
	r=$1 n=$2; shift 2
	out=$(T ask --root "$d" --repo "$r" --now "$n" "$@" 2>&1); rc=$?
	key=$(printf '%s' "$out" | cut -f1)
}
# w <seconds waited>: the since field for a unit that has waited that long at $base.
w() { echo $((base - $1)); }
sj() { python3 -I -c "import json,sys; d=json.load(open(sys.argv[1])); print(eval(sys.argv[2]))" "$1" "$2" 2>/dev/null; }

# Drain: the order in which units are given turns, one turn per 10 s, each started unit leaving its list.
# drain <tick> <repo>...: the repos' units are in $tmp/u.<repo>; sets seq and multi (turns given in one step).
drain() {
	t=$1; shift; seq= multi=0; step=0
	while [ $step -lt 14 ]; do
		for r in "$@"; do hb "$r" "$base"; list "$r" "$t" --gap 10 <"$tmp/u.$r"; done
		got=0
		for r in "$@"; do
			ask "$r" $((base + step * 10)) --gap 10 --starve 100000
			if [ -n "$key" ]; then
				got=$((got + 1)); seq="$seq $r/$key"
				grep -v "^$key " "$tmp/u.$r" >"$tmp/u.new"; mv "$tmp/u.new" "$tmp/u.$r"
			fi
		done
		[ $got -gt 1 ] && multi=1
		step=$((step + 1))
	done
	seq=${seq# }
}

# --- S07-AC-2: the order of the kinds, one repository.
reset
{
	echo "L1 fresh L $(w 500)"
	echo "Lm fresh - $(w 600)"
	echo "M1 fresh M $(w 100)"
	echo "S1 fresh S $(w 50)"
	echo "R1 resumed - $(w 10)"
	echo "F1 followup - $(w 20)"
	echo "U1 update - $(w 30)"
	echo "T1 triage - $(w 40)"
} >"$tmp/u.a"
drain 1000 a
if [ "$seq" = "a/T1 a/U1 a/F1 a/R1 a/S1 a/M1 a/Lm a/L1" ] && [ $multi = 0 ]; then pass "S07-AC-2 small kinds (triage, update, follow-up, resumed) by wait, then fresh S, M, L (missing Size = L, by wait)"; else fail "S07-AC-2 order: $seq"; fi

reset
{
	echo "A fresh S $(w 100)"
	echo "B fresh M $(w 900)"
	echo "C fresh L $(w 800)"
	echo "D triage - $(w 5)"
} >"$tmp/u.a"
drain 1000 a
if [ "$seq" = "a/D a/A a/B a/C" ]; then pass "S07-AC-2 a newer triage and a newer S node go before an older M and L node"; else fail "S07-AC-2 small before large: $seq"; fi

# ties: same wait -> repository name, then the loop's own order
reset
{ echo "Y2 fresh S $(w 100)"; echo "Y1 fresh S $(w 100)"; } >"$tmp/u.b"
{ echo "X1 fresh S $(w 100)"; } >"$tmp/u.a"
drain 1000 b a
if [ "$seq" = "a/X1 b/Y2 b/Y1" ]; then pass "S07-AC-2 ties by repository name, then the loop's own order (repositories asked b first)"; else fail "S07-AC-2 ties: $seq"; fi

# two repositories merged into one order
reset
{ echo "A1 fresh L $(w 700)"; echo "A2 fresh S $(w 60)"; echo "A3 triage - $(w 20)"; } >"$tmp/u.a"
{ echo "B1 fresh M $(w 300)"; echo "B2 fresh S $(w 90)"; echo "B3 followup - $(w 10)"; } >"$tmp/u.b"
drain 1000 a b
if [ "$seq" = "a/A3 b/B3 b/B2 a/A2 b/B1 a/A1" ] && [ $multi = 0 ]; then pass "S07-AC-2 two repositories' lists merge into one order, one turn per step"; else fail "S07-AC-2 merged: $seq"; fi

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

# --- S07-AC-3: two processes asking at the same moment
reset; hb a "$base"; hb b "$base"
multi=0 bad=0 none=0
i=0
while [ $i -lt 25 ]; do
	rm -f "$d/state/starts.json"
	echo "A1 triage - $(w 100)" | list a 1000
	echo "B1 triage - $(w 100)" | list b 1000
	( T ask --root "$d" --repo a --now "$base" --gap 100 >"$tmp/oa" 2>&1 ) &
	( T ask --root "$d" --repo b --now "$base" --gap 100 >"$tmp/ob" 2>&1 ) &
	wait
	n=0; [ -s "$tmp/oa" ] && n=$((n + 1)); [ -s "$tmp/ob" ] && n=$((n + 1))
	[ $n -gt 1 ] && multi=$((multi + 1))
	[ $n = 0 ] && none=$((none + 1))
	for f in "$d/state/starts.json" "$d/state/a/waiting.json" "$d/state/b/waiting.json"; do
		python3 -I -c "import json,sys; json.load(open(sys.argv[1]))" "$f" 2>/dev/null || bad=$((bad + 1))
	done
	i=$((i + 1))
done
[ $multi = 0 ] && [ $none = 0 ] && pass "S07-AC-3 25 rounds of two processes asking at once: exactly one turn each round" || fail "S07-AC-3 concurrent: $multi rounds with two turns, $none with none"
[ $bad = 0 ] && pass "S07-AC-3 the start record and the waiting lists stay well-formed JSON" || fail "S07-AC-3 $bad malformed files"
# concurrent lists and asks of the same loop
reset; hb a "$base"; hb b "$base"
i=0; bad=0; multi=0
while [ $i -lt 10 ]; do
	rm -f "$d/state/starts.json"
	echo "A1 triage - $(w 100)" | list a 1000
	echo "B1 fresh S $(w 100)" | list b 1000
	( echo "A1 triage - $(w 100)" | T list --root "$d" --repo a --tick 1000 --now "$base" >/dev/null 2>&1 ) &
	( T ask --root "$d" --repo a --now "$base" --gap 100 >"$tmp/oa" 2>&1 ) &
	( T ask --root "$d" --repo b --now "$base" --gap 100 >"$tmp/ob" 2>&1 ) &
	wait
	n=0; [ -s "$tmp/oa" ] && n=$((n + 1)); [ -s "$tmp/ob" ] && n=$((n + 1))
	[ $n -gt 1 ] && multi=$((multi + 1))
	for f in "$d/state/starts.json" "$d/state/a/waiting.json"; do
		python3 -I -c "import json,sys; json.load(open(sys.argv[1]))" "$f" 2>/dev/null || bad=$((bad + 1))
	done
	i=$((i + 1))
done
[ $multi = 0 ] && [ $bad = 0 ] && [ -s "$d/state/starts.json" ] && pass "S07-AC-3 a list written while both loops ask leaves well-formed files and at most one turn" || fail "S07-AC-3 list during ask: $multi double, $bad malformed"

# --- missing or malformed start record or waiting list
reset; hb a "$base"
echo "A1 triage - $(w 100)" | list a 1000
ask a "$base" --gap 10
if [ $rc = 0 ] && [ "$key" = A1 ] && [ "$(sj "$d/state/starts.json" "d['repo']+'/'+d['unit']")" = a/A1 ]; then pass "S07-AC-1 a missing start record means no start yet; the turn creates it"; else fail "missing start record: rc=$rc $out"; fi
for junk in 'not json' '' '[1,2]' '{"time": "x"}' '{"time": null, "repo": 3}'; do
	reset; hb a "$base"
	printf '%s\n' "$junk" >"$d/state/starts.json"
	echo "A1 triage - $(w 100)" | list a 1000
	ask a "$base" --gap 10
	if [ $rc = 0 ] && [ "$key" = A1 ] && [ "$(sj "$d/state/starts.json" "d['unit']")" = A1 ]; then pass "S07-AC-3 a malformed start record ($junk) is no last start; it is replaced by a well-formed one"; else fail "malformed start record '$junk': rc=$rc $out"; fi
done
for junk in 'not json' '' '{"tick": 100}' '{"units": 5, "tick": "x"}'; do
	reset; hb a "$base"; hb b "$base"
	echo "A1 fresh L $(w 100)" | list a 1000
	echo "B1 triage - $(w 100)" | list b 1000
	printf '%s\n' "$junk" >"$d/state/b/waiting.json"
	ask a "$base" --gap 10
	if [ $rc = 0 ] && [ "$key" = A1 ]; then pass "S07-AC-4 another loop's malformed waiting list ($junk) is left out; this loop still gets its turn"; else fail "malformed other waiting list '$junk': rc=$rc $out"; fi
done
reset; hb a "$base"; hb b "$base"
echo "B1 triage - $(w 100)" | list b 1000
ask a "$base" --gap 10
[ $rc = 0 ] && [ -z "$key" ] && pass "S07-AC-4 a loop that has listed nothing gets no turn, exit 0" || fail "no waiting list: rc=$rc $out"
reset; hb a "$base"; hb b "$base"
echo "B1 triage - $(w 100)" | list b 1000
printf 'not json\n' >"$d/state/a/waiting.json"
ask a "$base" --gap 10; r1=$rc k1=$key
ask b "$base" --gap 10
[ $r1 = 0 ] && [ -z "$k1" ] && [ $rc = 0 ] && [ "$key" = B1 ] && pass "S07-AC-4 a malformed own waiting list gives no turn and does not block the other loop" || fail "malformed own list: '$k1' rc=$r1 / rc=$rc $out"
reset; hb a "$base"
{ echo "bad line"; echo "X triage - soon"; echo "A1 triage - $(w 100)"; } | list a 1000; rc=$?
ask a "$base" --gap 10
[ $rc = 0 ] && [ "$key" = A1 ] && pass "S07-AC-4 malformed lines in a list are ignored, the others kept" || fail "malformed list lines: rc=$rc $out"
reset; hb a "$base"
: | list a 1000
ask a "$base" --gap 10
[ $rc = 0 ] && [ -z "$key" ] && [ -s "$d/state/a/waiting.json" ] && pass "S07-AC-1 an empty list is stored and gives no turn" || fail "empty list: rc=$rc $out"

echo
if [ $fails = 0 ]; then echo "all turn tests passed"; else echo "$fails turn test(s) failed"; exit 1; fi
