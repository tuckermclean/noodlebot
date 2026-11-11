#!/bin/sh
# Tests scheduler/turn.py (P03), part: `took`, the start of a released node that takes no turn (S07's start queue).
#   sh scheduler/turn-took.test.sh   (make test)
#   turn.py took --root DATA --repo NAME [--now EPOCH] KEY   records KEY's start in state/starts.json under starts.lock exactly
#   as a granted `ask` would ({"time", "repo", "unit", "prev"}), whatever the gap and the order; so `giveback KEY` restores
#   the previous record; exit 1 with a message on stderr on error (no KEY).
# The helpers are in testdata/lib/turn-common.sh.
set -u
src=$(cd "$(dirname "$0")" && pwd -P)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fails=0
. "$src/testdata/lib/turn-common.sh"
# took <repo> <now> <key> [extra args]: sets rc, out.
took() { r=$1 n=$2 k=$3; shift 3; out=$(T took --root "$d" --repo "$r" --now "$n" "$@" "$k" 2>&1); rc=$?; }
rec() { sj "$d/state/starts.json" "d['repo']+'/'+d['unit']+'@'+str(int(d['time']))"; }

# --- the start is recorded, with no waiting list and no start before
reset; hb a "$base"
took a "$base" A1
if [ $rc = 0 ] && [ "$(rec)" = "a/A1@$base" ] && [ "$(nbad "$d/state/starts.json")" = 0 ]; then pass "P03-AC-4 took records the unit's start in starts.json (no waiting list, no start before)"; else fail "took, empty state: rc=$rc out=$out rec=$(rec)"; fi

# --- whatever the gap: a recent start inside the gap is replaced by the released node's
reset; hb a "$base"; hb b "$base"
printf '{"time": %s, "repo": "b", "unit": "B9"}\n' $((base - 1)) >"$d/state/starts.json"
took a "$base" A1 --gap 1000
if [ $rc = 0 ] && [ "$(rec)" = "a/A1@$base" ]; then pass "P03-AC-4 took records the start although a start was a second ago and the gap is 1000 s"; else fail "took inside the gap: rc=$rc out=$out rec=$(rec)"; fi

# --- whatever the order: KEY is not first in the order, another loop's unit is
reset; hb a "$base"; hb b "$base"
{ echo "A0 triage - $(w 500)"; echo "A1 fresh L $(w 10)"; } | list a 10
echo "B1 triage - $(w 900)" | list b 10
took a "$base" A1
if [ $rc = 0 ] && [ "$(rec)" = "a/A1@$base" ]; then pass "P03-AC-4 took records the start of a unit that is not first in the order of the loops"; else fail "took out of order: rc=$rc out=$out rec=$(rec)"; fi

# --- an ask right after it gets no turn until the gap has passed, then gets one
reset; hb a "$base"
echo "A2 fresh L $(w 100)" | list a 10
took a "$base" A1
ask a $((base + 5)) --gap 10
if [ $rc = 0 ] && [ -z "$key" ]; then pass "P03-AC-4 an ask 5 s after a took (gap 10) gets no turn"; else fail "ask inside the gap after took: rc=$rc out=$out"; fi
ask a $((base + 10)) --gap 10
if [ $rc = 0 ] && [ "$key" = A2 ]; then pass "P03-AC-4 an ask a gap after the took gets its turn"; else fail "ask after the gap after took: rc=$rc out=$out"; fi

# --- the next start on a turn, in another loop, is a gap after it too
reset; hb a "$base"; hb b "$base"
echo "B1 triage - $(w 100)" | list b 10
took a "$base" A1
ask b $((base + 3)) --gap 10
r1=$rc k1=$key
ask b $((base + 10)) --gap 10
if [ $r1 = 0 ] && [ -z "$k1" ] && [ $rc = 0 ] && [ "$key" = B1 ]; then pass "P03-AC-4 the other loop's turn comes a gap after the took, not before"; else fail "other loop after took: '$k1' rc=$r1 / rc=$rc $out"; fi

# --- giveback after took restores the previous start record
reset; hb a "$base"
{ echo "A2 fresh L $(w 100)"; } | list a 10
ask a "$base" --gap 10
took a $((base + 20)) A1
giveback_out=$(T giveback --root "$d" --repo a A1 2>&1); grc=$?
if [ $grc = 0 ] && [ "$(rec)" = "a/A2@$base" ]; then pass "P03-AC-4 giveback after a took restores the previous start record"; else fail "giveback after took: rc=$grc out=$giveback_out rec=$(rec)"; fi

reset; hb a "$base"
echo "A2 fresh L $(w 100)" | list a 10
took a "$base" A1
tookrc=$rc
giveback_out=$(T giveback --root "$d" --repo a A1 2>&1); grc=$?
if [ $tookrc = 0 ] && [ $grc = 0 ] && [ ! -e "$d/state/starts.json" ]; then pass "P03-AC-4 giveback after a took with no start before leaves no start record"; else fail "giveback after took, none before: took rc=$tookrc rc=$grc out=$giveback_out, starts.json $(ls "$d/state")"; fi

# --- ask, giveback, then (same loop, no new list) took, giveback: the giveback restores the record before the took
reset; hb a "$base"
printf '{"time": %s, "repo": "b", "unit": "B9"}\n' $((base - 100)) >"$d/state/starts.json"
echo "A1 fresh L $(w 100)" | list a 10
ask a "$base" --gap 10
akey=$key
gb1=$(T giveback --root "$d" --repo a A1 2>&1); g1=$?
r_after_gb1=$(rec)
took a $((base + 20)) A1
tookrc=$rc
gb2=$(T giveback --root "$d" --repo a A1 2>&1); g2=$?
if [ "$akey" = A1 ] && [ $g1 = 0 ] && [ "$r_after_gb1" = "b/B9@$((base - 100))" ] && [ $tookrc = 0 ] && [ $g2 = 0 ] && [ "$(rec)" = "b/B9@$((base - 100))" ]; then pass "P03-AC-4 ask, giveback, took, giveback (same loop, no list between) restores the record before the took"; else fail "P03-AC-4 ask, giveback, took, giveback: ask key='$akey' gb=$g1/$g2 took rc=$tookrc rec after first giveback=$r_after_gb1, last=$(rec) ($gb1 $gb2)"; fi

# --- no KEY is an error
reset; hb a "$base"
printf '{"time": %s, "repo": "b", "unit": "B9"}\n' "$base" >"$d/state/starts.json"
out=$(T took --root "$d" --repo a --now "$base" 2>&1); rc=$?
if [ $rc != 0 ] && [ "$(rec)" = "b/B9@$base" ]; then pass "P03-AC-4 took without a KEY is an error and changes nothing"; else fail "took without KEY: rc=$rc out=$out rec=$(rec)"; fi

echo
if [ $fails = 0 ]; then echo "all turn tests passed"; else echo "$fails turn test(s) failed"; exit 1; fi
