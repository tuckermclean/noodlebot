#!/bin/sh
# Tests scheduler/turn.py (S07), part: two processes asking at once, concurrent lists and asks.
#   sh scheduler/turn-race.test.sh   (make test)
# The interface of turn.py and the helpers are in testdata/lib/turn-common.sh; the parts run at once.
set -u
src=$(cd "$(dirname "$0")" && pwd -P)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fails=0
. "$src/testdata/lib/turn-common.sh"

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
	bad=$((bad + $(nbad "$d/state/starts.json" "$d/state/a/waiting.json" "$d/state/b/waiting.json")))
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

echo
if [ $fails = 0 ]; then echo "all turn tests passed"; else echo "$fails turn test(s) failed"; exit 1; fi
