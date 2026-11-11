# Shared by turn-*.test.sh (S07): the interface of turn.py they fix and the helpers they run on.
# Sourced by the parts, after they set src, tmp and fails; not run on its own.
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
# nbad <file>...: how many of the files are not well-formed JSON (one python start for all of them).
nbad() { python3 -I -c "
import json, sys
n = 0
for f in sys.argv[1:]:
    try:
        json.load(open(f))
    except Exception:
        n += 1
print(n)" "$@" 2>/dev/null; }
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
