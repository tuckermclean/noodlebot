#!/bin/bash
# S08: the harness a loop runs (SCHED_HARNESS). Part of the end-to-end test of scheduler/loop.sh (fixture: testdata/lib/loop-s08.sh).
# The capabilities are in loop-s08-caps.test.sh; loops.sh passing SCHED_HARNESS is in loops-s08.test.sh.
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"   # the runner runs *.test.sh with sh, except loop.test.sh
. "$(dirname "$0")/testdata/lib/loop-prelude.sh"
. "$src/testdata/lib/loop-s08.sh"

# AC-5: SCHED_HARNESS=fake: a tick starts N01, the session ends idle by the usage limit, the loop resumes it; the `claude` on PATH fails on any call.
s08limit "$S08/limit.events" sid-N01; s08resumed "$S08/resumed.events" sid-N01
s08loop fk "$tmp/bin08" SCHED_HARNESS=fake S08_IDLE=1 FAKE_HARNESS_SCRIPT="$S08/limit.events" FAKE_HARNESS_RESUME_SCRIPT="$S08/resumed.events"
fkpid=$s08pid
# the two default runs: SCHED_HARNESS unset and "claude-code" run the Claude Code backend (the claude on PATH)
s08loop cc0 "$tmp/bin08cc" FAKE_HARNESS_SCRIPT="$S08/limit.events"
s08loop cc1 "$tmp/bin08cc" SCHED_HARNESS=claude-code FAKE_HARNESS_SCRIPT="$S08/limit.events"
# an unknown name: exit 2 with a message naming it, nothing started
s08root bad
timeout 30 env NOODLEBOT_DATA="$tmp/d-bad" PATH="$tmp/bin08:$PATH" SCHED_REPORT=0 SCHED_SITE=0 SCHED_TICK=1 SCHED_POLL=0.2 \
	SCHED_HARNESS=no-such-harness S08_DIR="$S08/bad" FAKE_HARNESS_LOG="$S08/bad.log" bash "$nb08/scheduler/loop.sh" o/bad >"$tmp/bad.out" 2>&1
badrc=$?

ok "S08-AC-5: SCHED_HARNESS=fake: the fake harness is asked to start N01" wait_until 20 s08calls_ge fk start 1
ok "S08-AC-5: SCHED_HARNESS=fake: the session, idle by the usage limit, is resumed through the harness with its session id" \
	wait_until 30 grep -q '^resume .* sid-N01' "$S08/fk.log"
s08ticks fk 3
ok "S08-AC-5: SCHED_HARNESS=fake: one start, one resume (the resume is no new start)" sh -c "[ \"\$(grep -c '^start ' '$S08/fk.log')\" = 1 ] && [ \"\$(grep -c '^resume ' '$S08/fk.log')\" = 1 ]"
ok "S08-AC-5: SCHED_HARNESS=fake: the status log says the usage limit stopped it and that it resumes" s08line fk 'resuming session N01 .*after the usage limit'
ok "S08-AC-5: SCHED_HARNESS=fake: the failing claude on PATH was never called" test ! -e "$S08/claude-called"
ok "S08-AC-5: SCHED_HARNESS=fake: the session's events are in events.jsonl of the node" grep -q '"type": *"usage"' "$tmp/d-fk/state/fk/node/N01/events.jsonl"

ok "S08-AC-5: SCHED_HARNESS unset runs the Claude Code backend (the claude on PATH is run)" wait_until 20 test -s "$S08/cc-cc0"
ok "S08-AC-5: SCHED_HARNESS=claude-code runs the Claude Code backend (the claude on PATH is run)" wait_until 20 test -s "$S08/cc-cc1"
ok "S08-AC-5: unset and claude-code run no fake harness" test ! -e "$S08/cc0.log" -a ! -e "$S08/cc1.log"
ok "S08-AC-5: an unknown harness name exits 2" test "$badrc" = 2
ok "S08-AC-5: an unknown harness name: the message names it" grep -q 'no-such-harness' "$tmp/bad.out"
ok "S08-AC-5: an unknown harness name starts nothing" sh -c "[ ! -e '$S08/bad.log' ] && [ ! -e '$tmp/d-bad/state/bad/node/N01/session.pid' ] && [ -z \"\$(ls '$tmp/d-bad/worktrees/bad' 2>/dev/null)\" ]"
kill "$fkpid" 2>/dev/null
loop_end
