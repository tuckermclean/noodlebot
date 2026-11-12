#!/bin/sh
# Tests scheduler/turn.py place (U03): a unit's place in the machine's start queue, read-only.
#   sh scheduler/turn-place.test.sh   (make test)
#
# Interface fixed by this test (the helpers are in testdata/lib/turn-common.sh):
#   python3 -I scheduler/turn.py place KEY --root DATA --repo NAME|OWNER/NAME [--gap S] [--starve S] [--now EPOCH]
#   KEY may come before or after the options; the part of --repo after the last / is the loop's folder name.
#   prints "<N> ahead, waited <H>h<MM>m, gap passed|gap not passed" (N units before KEY in the order ask
#   uses, live loops only, starved first, given-back units not counted) or "not waiting" (KEY not in this
#   repo's valid, live list); exit 0. It changes nothing: starts.json and every waiting.json stay
#   byte-identical, and no file or directory is created.
set -u
src=$(cd "$(dirname "$0")" && pwd -P)
tmp=$(mktemp -d)
trap 'chmod -R u+w "${tmp:?}" 2>/dev/null; rm -rf "${tmp:?}"' EXIT
fails=0
. "$src/testdata/lib/turn-common.sh"

# place <key> <repo> [extra args]: sets rc, out (stdout), err; KEY first.
place() {
	k=$1 r=$2; shift 2
	out=$(T place "$k" --root "$d" --repo "$r" --now "$base" "$@" 2>"$tmp/err"); rc=$?
	err=$(cat "$tmp/err")
}
# want <label> <expected stdout>: the last place gave exactly that and exited 0.
want() {
	if [ $rc = 0 ] && [ "$out" = "$2" ]; then pass "U03-AC-1 $1"; else fail "U03-AC-1 $1: rc=$rc out='$out' err='$err' (wanted '$2')"; fi
}

# units ahead of a key in one repository: small kinds first, then fresh S, M, L
reset; hb a "$base"
{
	echo "A1 triage - $(w 4500)"
	echo "A2 fresh S $(w 300)"
	echo "A3 fresh L $(w 600)"
	echo "A4 fresh M $(w 900)"
} >"$tmp/u.a"
list a 1000 <"$tmp/u.a"
place A1 a --gap 10; want "the first unit has 0 ahead" "0 ahead, waited 1h15m, gap passed"
place A2 a --gap 10; want "one repository: fresh S behind the triage has 1 ahead" "1 ahead, waited 0h05m, gap passed"
place A4 a --gap 10; want "one repository: fresh M has 2 ahead (triage, S)" "2 ahead, waited 0h15m, gap passed"
place A3 a --gap 10; want "one repository: fresh L has 3 ahead" "3 ahead, waited 0h10m, gap passed"

# across two repositories: the order is merged, by the rule of ask
reset; hb a "$base"; hb b "$base"
{ echo "A1 triage - $(w 400)"; echo "A2 fresh M $(w 5000)"; } | list a 1000
{ echo "B1 update - $(w 500)"; echo "B2 fresh S $(w 100)"; } | list b 1000
place B1 b --gap 10; want "two repositories: the longer-waiting small unit of b is first" "0 ahead, waited 0h08m, gap passed"
place A1 a --gap 10; want "two repositories: a's triage is behind b's update" "1 ahead, waited 0h06m, gap passed"
place B2 b --gap 10; want "two repositories: b's fresh S is behind both small units" "2 ahead, waited 0h01m, gap passed"
place A2 a --gap 10; want "two repositories: a's fresh M is behind three units of both loops" "3 ahead, waited 1h23m, gap passed"

# a unit past the starvation limit goes ahead of a smaller one
reset; hb a "$base"
{ echo "Sm fresh S $(w 100)"; echo "Lg fresh L $(w 2000)"; } | list a 1000
place Sm a --gap 10 --starve 1000; want "starved L is ahead of the smaller S" "1 ahead, waited 0h01m, gap passed"
place Lg a --gap 10 --starve 1000; want "the starved L is first" "0 ahead, waited 0h33m, gap passed"
place Sm a --gap 10 --starve 3000; want "below the starvation limit S is first" "0 ahead, waited 0h01m, gap passed"
SCHED_STARVE=1000 place Sm a --gap 10; want "the starvation limit from SCHED_STARVE" "1 ahead, waited 0h01m, gap passed"
# starvation across repositories
reset; hb a "$base"; hb b "$base"
echo "A1 triage - $(w 50)" | list a 1000
echo "B1 fresh L $(w 1500)" | list b 1000
place A1 a --gap 10 --starve 1000; want "another loop's starved unit is ahead of this loop's triage" "1 ahead, waited 0h00m, gap passed"

# a stale loop's list is left out
reset; hb a "$base"; hb b $((base - 4000))
echo "A1 fresh L $(w 100)" | list a 1000
echo "B1 triage - $(w 9000)" | list b 1000
place A1 a --gap 10; want "a stale loop's units are not ahead" "0 ahead, waited 0h01m, gap passed"
place B1 b --gap 10; want "a key in a stale loop's list is not waiting" "not waiting"
hb b $((base - 2999))
place A1 a --gap 10; want "a loop under three ticks old is live: its unit is ahead" "1 ahead, waited 0h01m, gap passed"
hb b $((base - 3000))
place A1 a --gap 10; want "a loop exactly three ticks old is stale" "0 ahead, waited 0h01m, gap passed"
reset; hb a "$base"
echo "A1 fresh L $(w 100)" | list a 1000
rm -f "$d/state/a/heartbeat"
place A1 a --gap 10; want "a loop without a heartbeat is left out" "not waiting"

# a key that is not waiting
reset; hb a "$base"; hb b "$base"
echo "A1 triage - $(w 100)" | list a 1000
echo "B1 triage - $(w 100)" | list b 1000
place ZZ a --gap 10; want "an absent key is not waiting" "not waiting"
place B1 a --gap 10; want "a key waiting in another repository is not waiting here" "not waiting"
place a1 a --gap 10; want "keys are case-sensitive" "not waiting"

# a missing or malformed list is treated as ask treats it: left out, never counted, the key not waiting
reset; hb a "$base"; hb c "$base"; hb e "$base"; hb f "$base"; hb g "$base"
echo "A1 fresh L $(w 100)" | list a 1000
printf 'not json at all' >"$d/state/c/waiting.json"
echo '{"tick": 1000, "units": "nope"}' >"$d/state/e/waiting.json"
echo '{"tick": 1000, "units": [{"key": "E1", "kind": "triage", "size": "-"}]}' >"$d/state/f/waiting.json"
: >"$d/state/g/waiting.json"
place A1 a --gap 10; want "malformed lists are left out of the count" "0 ahead, waited 0h01m, gap passed"
place C1 c --gap 10; want "a malformed list (not JSON): its key is not waiting" "not waiting"
place E1 e --gap 10; want "a malformed list (units not a list): not waiting" "not waiting"
place E1 f --gap 10; want "a malformed list (a unit without since): not waiting" "not waiting"
place G1 g --gap 10; want "an empty waiting.json: not waiting" "not waiting"
place A1 nolist --gap 10; want "a repository with no state folder: not waiting" "not waiting"
mkdir -p "$d/state/h"; hb h "$base"
place H1 h --gap 10; want "a repository with a heartbeat and no list: not waiting" "not waiting"
[ ! -e "$d/state/nolist" ] && [ "$rc" = 0 ] && [ "$out" = "not waiting" ] && pass "U03-AC-1 place does not create the folder of an unknown repository" || fail "U03-AC-1 place created state/nolist or failed"

# given-back units are not counted ahead (ask skips them)
reset; hb a "$base"
{ echo "A1 triage - $(w 900)"; echo "A2 fresh S $(w 300)"; echo "A3 fresh L $(w 200)"; } | list a 1000
T giveback A1 --root "$d" --repo a >/dev/null 2>&1
place A3 a --gap 10; want "a given-back unit is not counted ahead" "1 ahead, waited 0h03m, gap passed"

# the wait and the gap, against starts.json
reset; hb a "$base"; hb b "$base"
echo "A1 triage - $(w 4500)" | list a 1000
echo "B1 triage - $(w 60)" | list b 2000
gp() { # gp <label> <starts.json text or -> <expected tail> [extra args]
	lbl=$1 rec=$2 exp=$3; shift 3
	if [ "$rec" = - ]; then rm -f "$d/state/starts.json"; else printf '%s\n' "$rec" >"$d/state/starts.json"; fi
	place A1 a "$@"; want "$lbl" "0 ahead, waited 1h15m, $exp"
}
rec() { echo "{\"time\": $((base - $1)), \"repo\": \"b\", \"unit\": \"X\"}"; }
gp "gap not passed: last start 5 s ago, gap 10 s" "$(rec 5)" "gap not passed" --gap 10
gp "gap passed: last start exactly the gap ago" "$(rec 10)" "gap passed" --gap 10
gp "gap passed: last start 11 s ago" "$(rec 11)" "gap passed" --gap 10
gp "no starts.json: no start yet, gap passed" - "gap passed" --gap 10
gp "malformed starts.json: no start yet, gap passed" "not json" "gap passed" --gap 10
gp "starts.json without a time: gap passed" '{"repo": "b"}' "gap passed" --gap 10
gp "a start far in the future is a bad record: gap passed" "$(rec -1000)" "gap passed" --gap 10
gp "the gap from --gap: not passed at 50 s with 10000 s" "$(rec 50)" "gap not passed" --gap 10000
SCHED_START_GAP=100 gp "the gap from env SCHED_START_GAP (not passed at 50 s)" "$(rec 50)" "gap not passed"
SCHED_START_GAP=100 gp "env SCHED_START_GAP (passed at 150 s)" "$(rec 150)" "gap passed"
gp "default gap is the largest live tick (2000 s): not passed at 1500 s" "$(rec 1500)" "gap not passed"
gp "default gap is the largest live tick (2000 s): passed at 2000 s" "$(rec 2000)" "gap passed"
SCHED_START_GAP=100000 gp "--gap beats SCHED_START_GAP" "$(rec 50)" "gap passed" --gap 10

# KEY after the options (python 3.12.3 argparse), before them, and --repo as OWNER/NAME
reset; hb a "$base"
{ echo "A1 triage - $(w 100)"; echo "A2 fresh S $(w 100)"; } | list a 1000
out=$(T place --root "$d" --repo a --now "$base" --gap 10 A2 2>"$tmp/err"); rc=$?; err=$(cat "$tmp/err")
want "KEY after the options" "1 ahead, waited 0h01m, gap passed"
out=$(T place A2 --root "$d" --repo a --now "$base" --gap 10 2>"$tmp/err"); rc=$?; err=$(cat "$tmp/err")
want "KEY before the options" "1 ahead, waited 0h01m, gap passed"
out=$(T place --root "$d" --now "$base" --repo someone/a A2 --gap 10 2>"$tmp/err"); rc=$?; err=$(cat "$tmp/err")
want "--repo OWNER/NAME names the loop's folder after the last /" "1 ahead, waited 0h01m, gap passed"
out=$(T place --root "$d" --repo a --now "$base" --gap 10 NOPE 2>"$tmp/err"); rc=$?; err=$(cat "$tmp/err")
want "KEY after the options, not waiting" "not waiting"

# read-only: starts.json and every waiting.json byte-identical, nothing created, whatever the answer
reset; hb a "$base"; hb b "$base"
{ echo "A1 triage - $(w 400)"; echo "A2 fresh M $(w 5000)"; } | list a 1000
{ echo "B1 update - $(w 500)"; echo "B2 fresh S $(w 100)"; } | list b 1000
printf '%s\n' "{\"time\": $((base - 5)), \"repo\": \"b\", \"unit\": \"X\", \"prev\": null}" >"$d/state/starts.json"
mkdir "$tmp/snap"; cp -rp "$d" "$tmp/snap/d"
find "$d" | sort >"$tmp/files.before"
f0=$fails
place A2 a --gap 10; want "read-only run still answers" "3 ahead, waited 1h23m, gap not passed"
place ZZ a --gap 10; want "read-only run, key not waiting" "not waiting"
place B1 someone/b --gap 10 --starve 100000; want "read-only run with --starve and OWNER/NAME" "0 ahead, waited 0h08m, gap not passed"
place A1 nolist --gap 10; want "read-only run, unknown repository" "not waiting"
find "$d" | sort >"$tmp/files.after"
# the identity checks below count only when place ran (a place that fails changes nothing too)
ran() { [ $fails = $f0 ]; }
ran && cmp -s "$d/state/starts.json" "$tmp/snap/d/state/starts.json" && pass "U03-AC-1 starts.json is byte-identical after place" || fail "U03-AC-1 starts.json changed by place"
for r in a b; do
	ran && cmp -s "$d/state/$r/waiting.json" "$tmp/snap/d/state/$r/waiting.json" && pass "U03-AC-1 $r/waiting.json is byte-identical after place" || fail "U03-AC-1 $r/waiting.json changed by place"
done
ran && diff -r "$tmp/snap/d" "$d" >/dev/null 2>&1 && pass "U03-AC-1 the whole data folder is byte-identical after place" || fail "U03-AC-1 the data folder changed by place"
ran && cmp -s "$tmp/files.before" "$tmp/files.after" && pass "U03-AC-1 place creates no file or directory" || fail "U03-AC-1 place created or removed files: $(diff "$tmp/files.before" "$tmp/files.after" | tr '\n' ' ')"
# with no starts.json and no starts.lock, place makes neither
reset; mkdir -p "$d/state/a"; echo "$base" >"$d/state/a/heartbeat"
printf '{"tick": 1000, "units": [{"key": "A1", "kind": "triage", "size": "-", "since": %s}], "gaveback": []}\n' "$(w 100)" >"$d/state/a/waiting.json"
find "$d" | sort >"$tmp/files.before"
f0=$fails
place A1 a --gap 10; want "with no starts.json and no lock: answers" "0 ahead, waited 0h01m, gap passed"
find "$d" | sort >"$tmp/files.after"
ran && cmp -s "$tmp/files.before" "$tmp/files.after" && pass "U03-AC-1 place creates neither starts.lock nor starts.json" || fail "U03-AC-1 place created files: $(diff "$tmp/files.before" "$tmp/files.after" | tr '\n' ' ')"
# a read-only state folder: place still works (it needs no write access)
chmod a-w "$d/state" "$d/state/a"
place A1 a --gap 10; want "a read-only state folder: place still answers" "0 ahead, waited 0h01m, gap passed"
chmod u+w "$d/state" "$d/state/a"

# errors: non-zero exit with a message on stderr
place A1 a --gap 10 --now nan >/dev/null; [ $rc != 0 ] && [ -z "$out" ] && [ -s "$tmp/err" ] && pass "U03-AC-1 a non-finite --now is an error (non-zero, message on stderr)" || fail "U03-AC-1 --now nan: rc=$rc out='$out'"
out=$(T place --root "$d" --repo a --now "$base" 2>"$tmp/err"); rc=$?
[ $rc != 0 ] && [ -z "$out" ] && [ -s "$tmp/err" ] && pass "U03-AC-1 place without a KEY is an error: non-zero, a message on stderr" || fail "U03-AC-1 place without KEY: rc=$rc out='$out' err='$(cat "$tmp/err")'"

[ $fails = 0 ] && echo "ok: turn-place" || { echo "$fails failure(s)"; exit 1; }
