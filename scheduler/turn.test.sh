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

echo
if [ $fails = 0 ]; then echo "all turn tests passed"; else echo "$fails turn test(s) failed"; exit 1; fi
