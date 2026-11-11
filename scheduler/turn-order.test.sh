#!/bin/sh
# Tests scheduler/turn.py (S07), part: the order of the turns (S07-AC-2, S07-AC-4 starvation).
#   sh scheduler/turn-order.test.sh   (make test)
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

echo
if [ $fails = 0 ]; then echo "all turn tests passed"; else echo "$fails turn test(s) failed"; exit 1; fi
