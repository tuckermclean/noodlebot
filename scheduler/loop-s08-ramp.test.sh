#!/bin/bash
# S08-AC-6 under the start queue (SCHED_RAMP=1, the default): lacking resume, a limit-idle session is stopped and
# restarted as a new start at once. It does not wait in the queue as kind "resumed" (turn.py) and is not given a turn
# first, to be stopped, found unresumable and given back, which restarts it a turn late.
# Fixture: testdata/lib/loop-s08.sh (the fake harness, FAKE_HARNESS_CAPS=usage,bg-wait).
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"   # the runner runs *.test.sh with sh, except loop.test.sh
. "$(dirname "$0")/testdata/lib/loop-prelude.sh"
. "$src/testdata/lib/loop-s08.sh"
s08limit "$S08/limit.events" sid-N01
s08plain "$S08/plain.events"
s08root rq
# a watcher that records every kind the loop's waiting list ever holds (turn.py stores it in waiting.json)
W=$tmp/d-rq/state/rq/waiting.json kinds=$tmp/kinds
: >"$kinds"
( while :; do grep -o '"kind": *"[a-z]*"' "$W" 2>/dev/null >>"$kinds"; sleep 0.05; done ) &
pids+=("$!")
s08loop rq "$tmp/bin08" SCHED_RAMP=1 SCHED_START_GAP=1 SCHED_HARNESS=fake FAKE_HARNESS_CAPS=usage,bg-wait S08_IDLE=1 \
	FAKE_HARNESS_SCRIPT="$S08/limit.events" FAKE_HARNESS_RESUME_SCRIPT="$S08/plain.events"
ok "S08-AC-6 (ramp): the first start runs" wait_until 20 s08calls_ge rq start 1
ok "S08-AC-6 (ramp): the limit-idle session is restarted as a new start" wait_until 30 s08calls_ge rq start 2
s08ticks rq 3
ok "S08-AC-6 (ramp): the harness is never asked to resume" test "$(s08calls rq resume)" = 0
ok "S08-AC-6 (ramp): the status log says the session could not be resumed because the harness cannot" s08line rq 'could not be resumed: the harness cannot resume'
ok "S08-AC-6 (ramp): no start is granted a turn as kind resumed" test "$(s08n rq 'turn: resumed')" = 0
ok "S08-AC-6 (ramp): the session was never queued as kind resumed" test "$(grep -c resumed "$kinds")" = 0
ok "S08-AC-6 (ramp): no give-back of a failed resume" test "$(s08n rq 'giveback|given back')" = 0
ok "S08-AC-6 (ramp): the idle session was ended" sh -c "p=\$(cat '$S08/rq/pid.1' 2>/dev/null); [ -n \"\$p\" ] && ! kill -0 \"\$p\" 2>/dev/null"
loop_end
