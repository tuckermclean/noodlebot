#!/bin/bash
# T04: the loop's throttle holds for the 7-day pace unless USAGE_7D_PACE says otherwise. Part of the end-to-end test of
# scheduler/loop.sh. Two loop runs over their own remote: a ready node T01, and another repository's session log whose
# rate_limit_event gives an open 5-hour window and an allowed 7-day window 75% used at 57% of the week.
#   run 1 (T04-AC-1): USAGE_7D_PACE and USAGE_7D_MARGIN not in the loop's environment: the 7-day pace holds.
#   run 2 (T04-AC-2): USAGE_7D_PACE=0: nothing holds, the node starts.
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"   # the runner runs *.test.sh with sh, except loop.test.sh
. "$(dirname "$0")/testdata/lib/loop-prelude.sh"
exec </dev/null
T4=$tmp/t4; export T4
mkdir -p "$T4" "$tmp/bin-t4" "$tmp/nb-t4/scheduler" "$tmp/nb-t4/plugin"
for f in "$src"/*; do case $f in *.test.sh) ;; *) [ -f "$f" ] && cp "$f" "$tmp/nb-t4/scheduler/" ;; esac; done
[ -f "$src/harness.py" ] && { mkdir -p "$tmp/nb-t4/scheduler/harnesses"; cp "$src/harness.py" "$tmp/nb-t4/scheduler/"; cp "$src"/harnesses/*.py "$tmp/nb-t4/scheduler/harnesses/"; }
[ -f "$src/forge.py" ] && { mkdir -p "$tmp/nb-t4/scheduler/forges"; cp "$src/forge.py" "$tmp/nb-t4/scheduler/"; cp "$src"/forges/*.py "$tmp/nb-t4/scheduler/forges/"; }
git init -q -b main "$tmp/work-t4"; mkdir -p "$tmp/work-t4/docs"
printf 'nodes:\n  - {id: T01, name: ready-node, deps: []}\n' >"$tmp/work-t4/docs/graph.yaml"
git -C "$tmp/work-t4" add -A && git -C "$tmp/work-t4" -c user.name=t -c user.email=t@t commit -q -m init
git clone -q --bare "$tmp/work-t4" "$tmp/remote-t4.git"
cat >"$tmp/bin-t4/gh" <<'EOF2'
#!/bin/sh
case " $* " in
*"/issues?labels=noodlebot"*) echo '[]' ;;
*"/labels"*) cat >/dev/null; echo '{}' ;;
esac
exit 0
EOF2
# the fake claude counts its runs per loop in $T4/runs.<loop name> and leaves a question, so the node is not started again
cat >"$tmp/bin-t4/claude" <<'EOF2'
#!/bin/sh
n=$(( $(cat "$T4/runs.$T4_NAME" 2>/dev/null || echo 0) + 1 )); echo $n >"$T4/runs.$T4_NAME"
echo "Q1: held" >"$T4_STATE/node/T01/QUESTION.md"
exit 0
EOF2
chmod +x "$tmp/bin-t4/gh" "$tmp/bin-t4/claude"

# t4setup <name>: a data root with the clone and another repository's session log (5-hour window open, 7-day window
# 75% used, its reset 0.43 of a week away: 57% of the week gone). Sets dt4 and state.
t4setup() {
	dt4=$tmp/data-$1; state=$dt4/state/$1; T4_NAME=$1; T4_STATE=$state; export T4_NAME T4_STATE
	mkdir -p "$dt4/repos" "$dt4/state/other/node/Z01" "$state/node/T01"
	git clone -q "$tmp/remote-t4.git" "$dt4/repos/$1"
	printf '{"type":"rate_limit_event","rate_limit_info":{"status":"allowed","unifiedWindows":{"five_hour":{"utilization":0.02,"resetsAt":%s,"status":"allowed"},"seven_day":{"utilization":0.75,"resetsAt":%s,"status":"allowed"}}}}\n' \
		$(($(date +%s) + 14400)) $(($(date +%s) + 260064)) >"$dt4/state/other/node/Z01/session.jsonl"
}
t4runs() { cat "$T4/runs.$1" 2>/dev/null || echo 0; }
# t4limit <key>: the value of limits.<key> in the loop's usage.json, as JSON
t4limit() { python3 -I -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1]))["limits"].get(sys.argv[2], "MISSING")))' "$dt4/state/usage.json" "$1" 2>/dev/null; }
t4ran() { [ "$(t4runs "$1")" -ge 1 ]; }
t4is() { [ "$(t4limit "$1")" = "$2" ]; }
t4gone() { ! pgrep -f "$tmp/nb-t4/scheduler/loop.sh" >/dev/null 2>&1; }
t4stop() { touch "$HOME/STOP-$1"; wait_until 8 t4gone || { pkill -f "$tmp/nb-t4/scheduler/loop.sh" 2>/dev/null; wait_until 5 t4gone; }; rm -f "$HOME/STOP-$1"; }
t4has() { [ -s "$dt4/state/usage.json" ] && [ -e "$state/status.log" ]; }

# run 1: no USAGE_7D_PACE, no USAGE_7D_MARGIN in the loop's environment (the caller may have both)
t4setup one
env -u USAGE_7D_PACE -u USAGE_7D_MARGIN -u USAGE_5H_LIMIT NOODLEBOT_DATA=$dt4 PATH=$tmp/bin-t4:$PATH SCHED_REPORT=0 SCHED_TICK=1 SCHED_POLL=0.2 \
	bash "$tmp/nb-t4/scheduler/loop.sh" o/one >"$tmp/t4-one.out" 2>&1 &
pids+=("$!")
ok "T04-AC-1 setup: the throttle engages" within 10 'throttle engaged'
wait_ticks 3
ok "T04-AC-1: the status log has one 'throttle engaged' line" test "$(count 'throttle engaged')" = 1
ok "T04-AC-1: its reason names the 7-day window" grep -qE 'throttle engaged.*7-day window 75% used at 57% of the week' "$state/status.log"
ok "T04-AC-1: the ready node does not start within 3 ticks (no claude run)" test "$(t4runs one)" = 0
ok "T04-AC-1: nor is it logged as started" test "$(count 'started T01')" = 0
ok "T04-AC-1: usage.json's limits.seven_day_pace is true" t4is seven_day_pace true
ok "T04-AC-1: usage.json's limits.seven_day_margin is 0.1" t4is seven_day_margin 0.1
t4stop one

# run 2: USAGE_7D_PACE=0, the same readings
t4setup two
env -u USAGE_7D_MARGIN -u USAGE_5H_LIMIT USAGE_7D_PACE=0 NOODLEBOT_DATA=$dt4 PATH=$tmp/bin-t4:$PATH SCHED_REPORT=0 SCHED_TICK=1 SCHED_POLL=0.2 \
	bash "$tmp/nb-t4/scheduler/loop.sh" o/two >"$tmp/t4-two.out" 2>&1 &
pids+=("$!")
ok "T04-AC-2: the ready node starts (USAGE_7D_PACE=0)" waitf 15 t4ran two
ok "T04-AC-2 setup: the loop has read the windows" waitf 10 t4has
wait_ticks 2
ok "T04-AC-2: the status log has no 'throttle engaged' line" test "$(count 'throttle engaged')" = 0
ok "T04-AC-2: usage.json's limits.seven_day_pace is false" t4is seven_day_pace false
ok "T04-AC-2: the node's start is in the status log" test "$(count 'started T01')" -ge 1
t4stop two

loop_end
