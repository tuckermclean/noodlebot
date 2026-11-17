#!/bin/sh
# Tests scheduler/turn.py (S07), part: the order of the kinds, ties, merged repositories (S07-AC-2).
#   sh scheduler/turn.test.sh   (make test)
# The interface of turn.py and the helpers are in testdata/lib/turn-common.sh; the parts run at once.
set -u
src=$(cd "$(dirname "$0")" && pwd -P)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fails=0
. "$src/testdata/lib/turn-common.sh"

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

# --- A07 (adoption units): the adoption kind, `adopt`, goes with the triages in the start queue (the same group as triage,
# update, follow-up and resumed: before every fresh node, by wait within the group). Scratch under $tmp/A07.
tmp_a07_old=$tmp d_a07_old=$d
tmp=$tmp/A07; mkdir -p "$tmp"; d=$tmp/d
reset
{
	echo "A fresh S $(w 900)"
	echo "adopt-x adopt - $(w 5)"
	echo "T1 triage - $(w 40)"
} >"$tmp/u.a"
drain 1000 a
if [ "$seq" = "a/T1 a/adopt-x a/A" ]; then pass "A07-AC-1: an adoption unit goes with the triages: by wait inside the small group, before an older fresh S node"; else fail "A07-AC-1 adopt kind order: $seq"; fi
reset
{
	echo "L1 fresh L $(w 900)"
	echo "adopt-x adopt - $(w 60)"
	echo "T1 triage - $(w 40)"
	echo "U1 update - $(w 20)"
} >"$tmp/u.a"
drain 1000 a
if [ "$seq" = "a/adopt-x a/T1 a/U1 a/L1" ]; then pass "A07-AC-1: an older adoption unit goes before a newer triage and update, all before an older fresh L node"; else fail "A07-AC-1 adopt kind order 2: $seq"; fi
reset
hb a "$base"
{ echo "T1 triage - $(w 100)"; echo "A fresh S $(w 500)"; } | T list --root "$d" --repo a --tick 1000 --now "$base" >/dev/null 2>&1
out=$(T place adopt-x --root "$d" --repo a --kind adopt --now "$base" 2>&1); rc=$?
if [ $rc = 0 ] && printf '%s' "$out" | grep -q '^1 ahead'; then pass "A07-AC-1: turn.py place accepts --kind adopt: placed with the triages (1 ahead: the older triage, not the older fresh node)"; else fail "A07-AC-1 place --kind adopt (rc $rc): $out"; fi
reset
hb a "$base"
echo "adopt-x adopt - $(w 5)" | T list --root "$d" --repo a --tick 1000 --now "$base" >/dev/null 2>&1; rc=$?
out=$(T ask --root "$d" --repo a --now "$base" --gap 10 2>&1)
if [ $rc = 0 ] && [ "$(printf '%s' "$out" | cut -f1)" = adopt-x ] && printf '%s' "$out" | cut -f2 | grep -q '^turn: adopt'; then pass "A07-AC-1: list takes an adoption unit and ask gives it a turn named by its kind (turn: adopt)"; else fail "A07-AC-1 list/ask adopt (rc $rc): $out"; fi
tmp=$tmp_a07_old d=$d_a07_old

echo
if [ $fails = 0 ]; then echo "all turn tests passed"; else echo "$fails turn test(s) failed"; exit 1; fi
