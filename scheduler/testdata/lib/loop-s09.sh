# Shared by loop-s09*.test.sh (source after loop-prelude.sh): the fixture of the S09 (pickup agent) loop runs. It builds on
# the S08 fixture (testdata/lib/loop-s08.sh: the scheduler copy in $nb08 with the fake harness, remote08 with the node N01,
# s08ticks, s08n, s08calls ...) and adds:
#   a fake forge per run   $S09/fk/<name>: testdata/pickup/forge (issues 11-14 are the home issues of A01 B02 C03 D04 E05,
#                          PRs 20 21 26 27) over repo.git (a clone of remote08); the loop's spec is fake:$S09/fk/<name>, so
#                          its runtime name is <name>; its state folder (testdata/pickup/state: the units A01-F06 with
#                          their questions) is $tmp/d-<name>/state/<name>. Nothing in it is ready to start but N01 of the
#                          graph (a node a hold keeps from starting, a free slot starts).
#   a fake usage.py        in the scheduler copy: copies $S09_USAGE_JSON to <state root>/usage.json (as usage.py keeps its
#                          readings there) and prints the contents of $S09_USAGE_LINE ("hold: ..." or "open: ...").
#   s09world <name>        makes the forge and the state of a run;  s09comment <name> <issue> <text>   an owner comment
#   s09loop <name> [VAR=value...]   starts the loop of the run (pid in $s09pid), with the fake harness: SCHED_HARNESS=fake,
#                          FAKE_HARNESS_LOG=$S08/<name>.log, FAKE_HARNESS_SMALL_SCRIPT=$S09/<name>.small if it exists
#   s09st <name>           the run's state folder;  s09log <name> <regex>: its status log has such a line;
#   s09count <name> <regex>: how many lines;  s09small <name>: `small` calls logged;  s09units <name>: start/resume calls
. "$src/testdata/lib/loop-s08.sh"
S09=$tmp/s09; export S09
mkdir -p "$S09/fk" "$nb08/scheduler/testdata/forge"
cp "$src"/testdata/forge/*.py "$nb08/scheduler/testdata/forge/"
cat >"$nb08/scheduler/usage.py" <<'EOT'
import os, shutil, sys
a = sys.argv
root = a[a.index("--state-root") + 1]
if os.environ.get("S09_USAGE_JSON"):
    shutil.copyfile(os.environ["S09_USAGE_JSON"], os.path.join(root, "usage.json"))
print(open(os.environ["S09_USAGE_LINE"]).read().strip() if os.environ.get("S09_USAGE_LINE") else "open: fake")
EOT
# s09usage <file prefix> <hold|open> [five-hour utilization]: $S09/<prefix>.json and $S09/<prefix>.line
s09usage() {
	local r=$(($(date +%s) + 3600)) u=${3:-0.5} line="open: fake" hold=false
	[ "$2" != hold ] || { line="hold: 5-hour window projected to reach 95% before it resets (limit 90%)"; hold=true; }
	printf '{"windows": {"five_hour": {"resetsAt": %s, "utilization": %s, "status": "allowed"}, "seven_day": {"resetsAt": %s, "utilization": 0.1, "status": "allowed"}}, "hold": %s, "reason": "%s"}\n' \
		"$r" "$u" $((r + 600000)) "$hold" "${line#hold: }" >"$S09/$1.json"
	echo "$line" >"$S09/$1.line"
}
s09world() {
	local n=$1 d=$S09/fk/$1
	cp -R "$src/testdata/pickup/forge" "$d"
	git clone -q --bare "$tmp/remote08.git" "$d/repo.git"
	s08root "$n"
	cp -R "$src/testdata/pickup/state/." "$tmp/d-$n/state/$n/"
	# C03's question is answered: its home issue (13) has no question open, so an owner comment there is unplaceable
	printf "# Answer to C03 QUESTION.md\n\nThe owner's answer, posted by owner on GitHub at 2026-06-01T11:00:00Z: fake://owner/repo/issues/13#c1\n\nok\n" \
		>"$tmp/d-$n/state/$n/node/C03/ANSWER.md"
}
# s09seed <name>: report.py runs twice over the run's forge and state (as the first ticks of a loop would), so that its
# report.json exists: a comment added after it is new, not part of what the first run saw
s09seed() {
	local i
	for i in 1 2; do
		NOODLEBOT_NOW=2026-06-01T12:00:00 python3 -I "$nb08/scheduler/report.py" --repo "fake:$S09/fk/$1" --state "$(s09st "$1")" \
			--owner owner --worktrees "$tmp/d-$1/worktrees/$1" --clone "$tmp/d-$1/repos/$1" --version 9.9 --signature SIG-9 >/dev/null 2>&1
	done
}
# s09decide <name> <comment id> <action>: the pickup session's output for that one item (a $S09/<name>.small script, cost 0.0123)
s09decide() {
	python3 -I "$src/testdata/pickup/tool.py" script "$S09/$1.small" \
		"$(printf '[{"item": %s, "action": "%s", "reason": "r"}]' "$2" "$3")"
}
s09comment() { python3 -I "$src/testdata/pickup/tool.py" addc "$S09/fk/$1" "$2" owner 1 0 "$3"; }
s09loop() {
	local n=$1; shift
	local sm=(); [ ! -f "$S09/$n.small" ] || sm=(FAKE_HARNESS_SMALL_SCRIPT="$S09/$n.small")
	env NOODLEBOT_DATA="$tmp/d-$n" PATH="$tmp/bin08:$PATH" SCHED_REPORT=1 SCHED_SITE=0 SCHED_TICK=1 SCHED_POLL=0.2 \
		SCHED_HARNESS=fake S08_DIR="$S08/$n" FAKE_HARNESS_LOG="$S08/$n.log" "${sm[@]}" "$@" \
		bash "$nb08/scheduler/loop.sh" "fake:$S09/fk/$n" >>"$tmp/$n.out" 2>&1 &
	s09pid=$!; pids+=("$s09pid")
}
s09st() { echo "$tmp/d-$1/state/$1"; }
s09log() { grep -qE -- "$2" "$(s08st "$1")" 2>/dev/null; }
s09count() { s08n "$1" "$2"; }
s09small() { s08calls "$1" small; }
s09units() { echo $(($(s08calls "$1" start) + $(s08calls "$1" resume))); }

# ---- helpers of the test files ----
TOOL=$src/testdata/pickup/tool.py
tool() { python3 -I "$TOOL" "$@"; }
fk() { echo "$S09/fk/$1"; }
nrec() { tool notrec "$(fk "$1")" | wc -l; }                       # nrec <run>: the "Not recorded" replies the bot posted
ge() { [ "$("$1" "${@:3}")" -ge "$2" ]; }                          # ge <function> <n> <args>: its number is at least n
is() { [ "$("$1" "${@:3}")" = "$2" ]; }                            # is <function> <n> <args>: its number is n
handled() { grep -qx "$2" "$(s09st "$1")/pickup/handled" 2>/dev/null; }
# dl <cmd...>: wait for the condition until DL (an epoch second, set by the file when its loops are started): all the "this
# must happen" checks share one time limit, so that a file whose subject is missing does not wait for each of them
DL=0
dl() { local left=$((DL - $(date +%s))); [ "$left" -ge 0 ] || left=0; wait_until "$left" "$@"; }
stop_loop() { kill "$1" 2>/dev/null; wait "$1" 2>/dev/null; wait_until 10 flock -n "$(s09st "$2")/loop.lock" true; }
# The ticks of the loops are counted in the background ($S09/<name>.hb: one line per heartbeat), so that the "nothing
# happened" checks of all runs wait for their ticks at the same time: ticker <name> starts it, tk <name> is the count,
# mark <name>... remembers it, ticks_since <n> <name>... waits for n ticks of each since its mark.
ticker() { ( last=''; while :; do v=$(cat "$(s09st "$1")/heartbeat" 2>/dev/null); [ "$v" = "$last" ] || { echo "$v" >>"$S09/$1.hb"; last=$v; }; sleep 0.1; done ) &
	pids+=($!); }
tk() { local c; c=$(wc -l <"$S09/$1.hb" 2>/dev/null); echo "${c:-0}"; }
tkge() { [ "$(tk "$1")" -ge "$2" ]; }
mark() { local n; for n in "$@"; do eval "MK_$n=$(tk "$n")"; done; }
ticks_since() { local n=$1 l m; shift; for l in "$@"; do eval "m=\$MK_$l"; wait_until $((n * 10 + 10)) tkge "$l" $((m + n)) || return 1; done; }
# setup <name> <hold|open> [utilization]: the world, the seeded report, one owner comment on C03's home issue (13: no question
# is open there; id in $ID_<name>) and the pickup session's script for it (a note), the usage reading of the run
setup() {
	s09world "$1"; s09seed "$1"; s09usage "u$1" "$2" "${3:-0.5}"
	local id; id=$(s09comment "$1" 13 "an unplaceable owner comment for run $1"); eval "ID_$1=$id"
	s09decide "$1" "$id" note
}
UV() { echo S09_USAGE_JSON="$S09/u$1.json" S09_USAGE_LINE="$S09/u$1.line"; }
s08plain "$S08/plain.events"
