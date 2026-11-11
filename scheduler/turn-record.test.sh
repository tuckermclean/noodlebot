#!/bin/sh
# Tests scheduler/turn.py (S07), part: missing or malformed records, non-finite numbers, odd units.
#   sh scheduler/turn-record.test.sh   (make test)
# The interface of turn.py and the helpers are in testdata/lib/turn-common.sh; the parts run at once.
set -u
src=$(cd "$(dirname "$0")" && pwd -P)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fails=0
. "$src/testdata/lib/turn-common.sh"

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


# --- S07-AC-1 / S07-AC-3: a start record slightly in the future of the asker's now is a real start
reset; hb a "$base"; hb b "$base"
echo "B1 triage - $(w 100)" | list b 60
echo "A1 fresh L $(w 100)" | list a 60
ask b $((base + 30)) --gap 60
[ $rc = 0 ] && [ "$key" = B1 ] && pass "S07-AC-1 (setup) b's unit gets the turn at base+30" || fail "S07-AC-1 future setup: rc=$rc $out"
: | list b 60
ask a $((base + 20)) --gap 60
[ $rc = 0 ] && [ -z "$key" ] && pass "S07-AC-1 a start 10 s in the asker's future still counts: no turn 10 s before it with a gap of 60" || fail "S07-AC-1 start slightly in the future ignored (two starts 10 s apart): rc=$rc $out"
ask a $((base + 90)) --gap 60
[ $rc = 0 ] && [ "$key" = A1 ] && pass "S07-AC-1 and a turn 60 s after that start" || fail "S07-AC-1 turn after the future start: rc=$rc $out"
for t in 1e300 $((base + 61)) $((base + 1000000)); do
	reset; hb a "$base"
	printf '{"time": %s, "repo": "b", "unit": "Z9"}\n' "$t" >"$d/state/starts.json"
	echo "A1 triage - $(w 100)" | list a 60
	ask a "$base" --gap 60
	[ $rc = 0 ] && [ "$key" = A1 ] && pass "S07-AC-3 a start record far in the future (time $t) is malformed: a turn is given" || fail "S07-AC-3 absurd future start $t: rc=$rc $out"
done

# --- S07-AC-4: non-finite numbers never crash or block
for junk in inf -inf nan; do
	reset; hb a "$base"; hb b "$base"
	{ echo "B1 triage - $junk"; echo "B2 triage - $(w 50)"; } | list b 100
	echo "A1 fresh L $(w 10)" | list a 100
	ask a "$base" --gap 10; ra=$rc ka=$key
	ask b "$base" --gap 10; rb=$rc
	[ $ra = 0 ] && [ "$ka" = A1 ] && pass "S07-AC-4 a list line with since $junk is dropped; the other loop still gets its turn" || fail "S07-AC-4 since $junk: other loop rc=$ra [$ka]"
	[ $rb = 0 ] && pass "S07-AC-4 and the loop that listed since $junk exits 0 on ask" || fail "S07-AC-4 ask after since $junk: rc=$rb"
done
for junk in 'Infinity' 'NaN' '-Infinity'; do
	reset; hb a "$base"; hb b "$base"
	echo "A1 fresh L $(w 10)" | list a 100
	printf '{"tick": 100, "units": [{"key": "B1", "kind": "triage", "size": "-", "since": %s}], "gaveback": []}\n' "$junk" >"$d/state/b/waiting.json"
	ask a "$base" --gap 10
	[ $rc = 0 ] && [ "$key" = A1 ] && pass "S07-AC-4 a hand-written waiting.json with since $junk leaves that loop out; others get turns" || fail "S07-AC-4 hand since $junk: rc=$rc [$out]"
	ask b "$base" --gap 10
	[ $rc = 0 ] && pass "S07-AC-4 the same loop's ask exits 0" || fail "S07-AC-4 hand since $junk own ask: rc=$rc [$out]"
done
for junk in Infinity NaN; do
	reset; hb a "$base"; hb b "$base"
	echo "A1 fresh L $(w 10)" | list a 100
	printf '{"tick": %s, "units": [{"key": "B1", "kind": "triage", "size": "-", "since": %s}], "gaveback": []}\n' "$junk" $((base - 500)) >"$d/state/b/waiting.json"
	printf '{"time": %s, "repo": "z", "unit": "Z9"}\n' $((base - 1000)) >"$d/state/starts.json"
	ask a "$base"
	[ $rc = 0 ] && [ "$key" = A1 ] && pass "S07-AC-4 a hand-written tick $junk leaves that loop out (no infinite gap); the other loop gets its turn" || fail "S07-AC-4 hand tick $junk: rc=$rc [$out]"
	ask b "$base"
	[ $rc = 0 ] && pass "S07-AC-4 and its own ask exits 0" || fail "S07-AC-4 hand tick $junk own ask: rc=$rc [$out]"
done
for tk in inf -inf nan 0 -5; do
	reset; hb a "$base"; hb b "$base"
	echo "A1 triage - $(w 10)" | list a 100
	echo "B1 fresh L $(w 10)" | T list --root "$d" --repo b --tick "$tk" --now "$base" >/dev/null 2>&1
	printf '{"time": %s, "repo": "z", "unit": "Z9"}\n' $((base - 1000)) >"$d/state/starts.json"
	ask a "$base"
	[ $rc = 0 ] && [ "$key" = A1 ] && pass "S07-AC-4 list --tick $tk does not make the default gap infinite or crash the other loop's ask" || fail "S07-AC-4 list --tick $tk: other loop rc=$rc [$out]"
done

# --- S07-AC-4: regression, units missing fields or of the wrong type in another loop's list
for unit in '{"since": 1, "size": "L", "kind": "triage"}' '{"since": 1, "size": "L", "key": "B1"}' '{"key": "B1", "kind": "fresh", "size": ["L"], "since": 1}' '{"key": "B1", "kind": "fresh", "size": "L"}' '5'; do
	reset; hb a "$base"; hb b "$base"
	echo "A1 fresh L $(w 10)" | list a 100
	printf '{"tick": 100, "units": [%s], "gaveback": []}\n' "$unit" >"$d/state/b/waiting.json"
	ask a "$base" --gap 10
	[ $rc = 0 ] && [ "$key" = A1 ] && pass "S07-AC-4 another loop's unit $unit does not crash or block the others' ask" || fail "S07-AC-4 odd unit $unit: rc=$rc [$out]"
done
# giving back the same grant twice leaves the earlier record, never deletes it
reset; hb a "$base"
printf '{"time": %s, "repo": "b", "unit": "Z9"}\n' $((base - 1000)) >"$d/state/starts.json"
{ echo "A1 triage - $(w 100)"; echo "A2 triage - $(w 50)"; } | list a 1000
ask a "$base" --gap 10
T giveback A1 --root "$d" --repo a --now "$base" >/dev/null 2>&1; r1=$?
T giveback A1 --root "$d" --repo a --now "$base" >/dev/null 2>&1; r2=$?
if [ $r1 = 0 ] && [ $r2 = 0 ] && [ -f "$d/state/starts.json" ] && [ "$(sj "$d/state/starts.json" "d['time']")" = $((base - 1000)) ] && [ "$(sj "$d/state/starts.json" "d['unit']")" = Z9 ]; then pass "S07-AC-4 giving back the same grant twice leaves the record from before the grant"; else fail "S07-AC-4 double give-back: $r1 $r2 $(cat "$d/state/starts.json" 2>&1)"; fi
ask a "$base" --gap 10
case $out in A2"	"*"ahead of A1"*) pass "S07-AC-4 a given-back unit that waited longer is named in the next grant's 'ahead of'" ;; *) fail "S07-AC-4 ahead of a given-back unit: rc=$rc [$out]" ;; esac

echo
if [ $fails = 0 ]; then echo "all turn tests passed"; else echo "$fails turn test(s) failed"; exit 1; fi
