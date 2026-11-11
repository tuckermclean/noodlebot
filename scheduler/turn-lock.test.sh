#!/bin/sh
# Tests scheduler/turn.py (S07), part: the lock: twelve asks of one loop at once, an ask racing a list.
#   sh scheduler/turn-lock.test.sh   (make test)
# The interface of turn.py and the helpers are in testdata/lib/turn-common.sh; the parts run at once.
set -u
src=$(cd "$(dirname "$0")" && pwd -P)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fails=0
. "$src/testdata/lib/turn-common.sh"

# --- S07-AC-3: the lock; the same loop asking twice, an ask racing a list
reset; hb a "$base"
multi=0 none=0 bad=0
i=0
while [ $i -lt 30 ]; do
	rm -f "$d/state/starts.json" "$tmp"/o[1-9] "$tmp"/o1[0-2]
	{ echo "A1 triage - $(w 100)"; echo "A2 triage - $(w 50)"; } | list a 1000
	# The twelve askers wait on a shared lock on $tmp/gate (no spinning) and start together when it is released.
	exec 9>"$tmp/gate"; flock -x 9
	for j in 1 2 3 4 5 6 7 8 9 10 11 12; do ( flock -s 8; T ask --root "$d" --repo a --now "$base" --gap 60 >"$tmp/o$j" 2>&1 ) 8<"$tmp/gate" & done
	sleep 0.1 # nothing to observe: lets the askers reach the lock; one that is late only races less
	flock -u 9; exec 9>&-
	wait
	n=0; for j in 1 2 3 4 5 6 7 8 9 10 11 12; do [ -s "$tmp/o$j" ] && n=$((n + 1)); done
	[ $n -gt 1 ] && multi=$((multi + 1))
	[ $n = 0 ] && none=$((none + 1))
	bad=$((bad + $(nbad "$d/state/starts.json")))
	i=$((i + 1))
done
[ $multi = 0 ] && [ $none = 0 ] && [ $bad = 0 ] && pass "S07-AC-3 30 rounds of twelve asks from the same loop at the same moment: exactly one grant each round, starts.json well-formed" || fail "S07-AC-3 same-loop asks: $multi rounds with two grants, $none with none, $bad malformed"
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
	fs=
	for f in "$d/state/starts.json" "$d/state/a/waiting.json" "$d/state/b/waiting.json"; do
		[ -e "$f" ] || continue   # the list may reach b's ask first: then nobody is granted
		fs="$fs $f"
	done
	bad=$((bad + $(nbad $fs)))
	i=$((i + 1))
done
[ $multi = 0 ] && [ $bad = 0 ] && pass "S07-AC-3 an ask racing a list that changes the head unit: never two grants, files well-formed" || fail "S07-AC-3 ask racing list: $multi double grants, $bad malformed files"

echo

echo
if [ $fails = 0 ]; then echo "all turn tests passed"; else echo "$fails turn test(s) failed"; exit 1; fi
