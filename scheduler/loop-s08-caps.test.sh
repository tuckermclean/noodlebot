#!/bin/bash
# S08: a capability the harness lacks turns its feature off, said once per loop start in the status log, the tick carries on.
# Part of the end-to-end test of scheduler/loop.sh (fixture: testdata/lib/loop-s08.sh; the fake harness's FAKE_HARNESS_CAPS).
#   usage    -> "harness fake lacks usage: throttle off"            the throttle holds nothing
#   resume   -> "harness fake lacks resume: limit resume off"       a limit-idle session is ended and restarted as a new start
#   bg-wait  -> "harness fake lacks bg-wait: cut-off check off"     the background cut-off check is skipped
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"   # the runner runs *.test.sh with sh, except loop.test.sh
. "$(dirname "$0")/testdata/lib/loop-prelude.sh"
. "$src/testdata/lib/loop-s08.sh"
lacks() { echo "harness fake lacks $1: $2 off"; }
s08n_is() { [ "$(s08n "$1" "$2")" = "$3" ]; }
L_USAGE=$(lacks usage throttle) L_RESUME=$(lacks resume 'limit resume') L_BG=$(lacks bg-wait 'cut-off check')
ALL=usage,resume,bg-wait

s08limit "$S08/limit.events" sid-N01; s08resumed "$S08/resumed.events" sid-N01; s08plain "$S08/plain.events"
printf 'Background tasks still running after the last turn; stopping them.\n' >"$S08/cut.stderr"
printf '{"type":"start","t":null,"session":"sid-N01"}\n{"type":"cutoff","t":null}\n' >"$S08/cut.events"
# the throttle would hold: another repository's session is rejected on the five-hour window, resetting in an hour
hold() {
	local d=$tmp/d-$1/state/other/node/Z01 r=$(($(date +%s) + 3600))
	mkdir -p "$d"
	printf '{"type":"usage","t":null,"status":"rejected","has_status":true,"info_bad":false,"reset":%s,"window":"five_hour","utilization":1.0,"windows":{"five_hour":{"status":"rejected","has_status":true,"utilization":1.0,"reset":%s}}}\n' "$r" "$r" >"$d/events.jsonl"
	printf '{"type":"rate_limit_event","rate_limit_info":{"status":"rejected","resetsAt":%s,"rateLimitType":"five_hour","unifiedWindows":{"five_hour":{"utilization":1.0,"resetsAt":%s,"status":"rejected"}}}}\n' "$r" "$r" >"$d/session.jsonl"
}
for n in cu cuc; do s08root $n; hold $n; done
s08loop cu "$tmp/bin08" SCHED_HARNESS=fake FAKE_HARNESS_CAPS=resume,bg-wait FAKE_HARNESS_SCRIPT="$S08/plain.events"
cupid=$s08pid
s08loop cuc "$tmp/bin08" SCHED_HARNESS=fake FAKE_HARNESS_CAPS=$ALL FAKE_HARNESS_SCRIPT="$S08/plain.events"
s08loop cr "$tmp/bin08" SCHED_HARNESS=fake FAKE_HARNESS_CAPS=usage,bg-wait S08_IDLE=1 FAKE_HARNESS_SCRIPT="$S08/limit.events" FAKE_HARNESS_RESUME_SCRIPT="$S08/resumed.events"
s08loop cb "$tmp/bin08" SCHED_HARNESS=fake FAKE_HARNESS_CAPS=usage,resume S08_STDERR="$S08/cut.stderr" FAKE_HARNESS_SCRIPT="$S08/cut.events"
s08loop cbc "$tmp/bin08" SCHED_HARNESS=fake FAKE_HARNESS_CAPS=$ALL S08_STDERR="$S08/cut.stderr" FAKE_HARNESS_SCRIPT="$S08/cut.events"

# ---- usage: the throttle holds nothing ----
ok "S08-AC-6 (usage): lacking usage readings, a reading that would hold does not: N01 starts" wait_until 20 s08calls_ge cu start 1
ok "S08-AC-6 (usage): the tick carries on: the node's session ran to its end" wait_until 20 s08line cu 'session N01 ended'
s08ticks cu 3
ok "S08-AC-6 (usage): the throttle never engages" test "$(s08n cu 'throttle engaged')" = 0
ok "S08-AC-6 (usage): said once in the status log after several ticks: $L_USAGE" test "$(s08n cu "$L_USAGE")" = 1
ok "S08-AC-6 (usage): only the missing capability is said" test "$(s08n cu 'lacks ')" = 1
ok "S08-AC-6 (control): with every capability the same reading holds: the throttle engages" wait_until 20 s08line cuc 'throttle engaged'
s08ticks cuc 3
ok "S08-AC-6 (control): with every capability and the hold, no session starts" test "$(s08calls cuc start)" = 0
ok "S08-AC-6 (control): with every capability nothing is said to be lacking" test "$(s08n cuc 'lacks ')" = 0
# once per loop start: a second start of the loop says it again
kill "$cupid"; wait "$cupid" 2>/dev/null
ok "S08-AC-6 (usage): the stopped loop released its lock" wait_until 10 flock -n "$tmp/d-cu/state/cu/loop.lock" true
s08loop cu "$tmp/bin08" SCHED_HARNESS=fake FAKE_HARNESS_CAPS=resume,bg-wait FAKE_HARNESS_SCRIPT="$S08/plain.events"
ok "S08-AC-6 (usage): a second loop start says it again" wait_until 20 s08n_is cu "$L_USAGE" 2
s08ticks cu 3
ok "S08-AC-6 (usage): and only once more" test "$(s08n cu "$L_USAGE")" = 2

# ---- resume: a limit-idle session is ended and restarted as a new start ----
ok "S08-AC-6 (resume): lacking resume, the first start runs" wait_until 20 s08calls_ge cr start 1
ok "S08-AC-6 (resume): the limit-idle session is restarted as a new start" wait_until 30 s08calls_ge cr start 2
s08ticks cr 3
ok "S08-AC-6 (resume): the harness is never asked to resume" test "$(s08calls cr resume)" = 0
ok "S08-AC-6 (resume): the status log does not say it resumed a session" test "$(s08n cr 'resuming session')" = 0
ok "S08-AC-6 (resume): the idle session was ended" sh -c "p=\$(cat '$S08/cr/pid.1' 2>/dev/null); [ -n \"\$p\" ] && ! kill -0 \"\$p\" 2>/dev/null"
ok "S08-AC-6 (resume): said once in the status log after several ticks: $L_RESUME" test "$(s08n cr "$L_RESUME")" = 1
ok "S08-AC-6 (resume): only the missing capability is said" test "$(s08n cr 'lacks ')" = 1

# ---- bg-wait: the cut-off check is skipped ----
ok "S08-AC-6 (bg-wait): lacking the background-wait setting, N01 starts and its session ends" wait_until 20 s08line cb 'session N01 ended \(rc 0\)'
ok "S08-AC-6 (control): with every capability the cut-off ends it as cut off, start not counted" wait_until 20 s08line cbc 'background work cut off; start not counted'
s08ticks cb 3
ok "S08-AC-6 (bg-wait): a session with a cut-off in its events and stderr ends as an ordinary end" s08line cb 'session N01 ended \(rc 0\), no PR, no QUESTION.md; may start again'
ok "S08-AC-6 (bg-wait): the cut-off check is not made: no cut-off line" test "$(s08n cb 'cut off')" = 0
ok "S08-AC-6 (bg-wait): said once in the status log after several ticks: $L_BG" test "$(s08n cb "$L_BG")" = 1
ok "S08-AC-6 (bg-wait): only the missing capability is said" test "$(s08n cb 'lacks ')" = 1
ok "S08-AC-6 (control): with every capability nothing is said to be lacking" test "$(s08n cbc 'lacks ')" = 0
loop_end
