#!/bin/bash
# S06: idle sessions resumed after the usage limit, the checks made eight ticks after the resumes. Part of the end-to-end test of scheduler/loop.sh.
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"   # the runner runs *.test.sh with sh, except loop.test.sh
. "$(dirname "$0")/testdata/lib/loop-prelude.sh"
. "$src/testdata/lib/loop-s06.sh"

# ---- S06: a session the usage limit left idle is resumed, or restarted when that is not possible: the later checks ----
# The run of loop-s06.test.sh (see its header for the fakes and what each session does), up to the moment its checks of
# S06-AC-5 and S06-AC-2 are made: those checks, and the harness checks, are made there; here a wait prints FAIL only when it
# runs out. One difference: while the throttle holds, the loop has one tick here, not six. Those six ticks are the window of
# the "neither stopped nor resumed while the throttle holds" checks in loop-s06.test.sh; while it holds the loop does nothing
# with an idle session (no resume, no stop, no record), so the state at the release is the same (K03's reset is still under
# 2 minutes old, as it is there). From the release on, every tick and wait is the base's: four ticks after the resumes,
# K02's hold goes, four ticks after its second rejection, then the checks.
. "$src/testdata/lib/loop-s06-main.sh"
touch "$S06/hold.K01" "$S06/hold.K02" "$S06/hold.issue-46" "$S06/hold.pr-101"
NOODLEBOT_DATA=$data06 PATH=$tmp/bin06:$PATH SCHED_REPORT=0 SCHED_TICK=1 SCHED_POLL=0.2 \
	bash "$nb06/scheduler/loop.sh" o/s06 >>"$tmp/s06-loop.out" 2>&1 &
pids+=("$!"); lp06=$!
x6part=$(basename "$0")
x6wait 20 x6have up.K01 up.K02 up.K03 up.K04 up.K05 up.K06 up.issue-46 || fail "S06 (harness): the six nodes and the triage session are running (in $x6part)"
x6rejected $(($(date +%s) + 3600)) >"$data06/state/other/node/Z01/session.jsonl"
x6wait 8 grep -q 'throttle engaged' "$st06/status.log" || fail "S06 (harness): the throttle engages (in $x6part)"
touch "$S06/arm"
x6wait 8 x6have armed.K01 armed.K02 armed.K03 armed.K04 armed.K05 armed.K06 armed.issue-46 || fail "S06 (harness): the sessions write their rejections (in $x6part)"
wait_ticks 1 "$st06"   # the loop has seen the rejections under the hold (see above)
x6allowed $(($(date +%s) + 7200)) $(($(date +%s) + 3 * 86400)) >>"$data06/state/other/node/Z01/session.jsonl"
x6wait 8 grep -q 'throttle released' "$st06/status.log" || fail "S06-AC-5 (harness): the throttle releases (in $x6part)"
x6wait 25 x6have resumed-up.K01 resumed-up.K02 resumed-up.issue-46 resumed-up.K06 args.K05.2 args.K06.3 || fail "S06 (harness): the resumes and restarts have run (in $x6part)"
wait_ticks 4 "$st06"   # the old fixed sleep was 4 s (loop-s06.test.sh makes its checks of the resumes here)
# K02's resumed run writes the same rejection again as soon as its hold goes; "resumed once" and the checks after it come
# four ticks later (the old fixed sleep was 4 s), as in the base: eight ticks after the resumes in all
rm -f "$S06/hold.K02"
x6wait 10 sh -c "[ \"\$(grep -c 'rate_limit_event' '$st06/node/K02/session.jsonl')\" = 2 ]"
wait_ticks 4 "$st06"
x6ok "S06-AC-3: K02 was resumed once, though its log ends with the same rejection again" sh -c "[ '$(x6runs K02)' = 2 ] && [ '$(x6res_n K02)' = 1 ] && [ \"\$(grep -c 'rate_limit_event' '$st06/node/K02/session.jsonl')\" = 2 ]"
x6ok "S06-AC-3: K01's resumed process is the only K01 session while it runs" sh -c "[ '$(x6runs K01)' = 2 ] && [ \"\$(grep -c 'started K01 ' '$st06/status.log')\" = 1 ]"
x6ok "S06-AC-2 (harness): the resume prompt template scheduler/limit-resume.md exists" test -s "$src/limit-resume.md"
x6ok "S06-AC-2: scheduler/limit-resume.md says the usage limit stopped the run and has reset, background agents and commands were killed; check, re-dispatch, carry on" x6prompt_says "$src/limit-resume.md"
# AC-1: working again, or reset less than 2 minutes ago
for k in K03 K04; do
	x6ok "S06-AC-1: $k (reset under 2 minutes ago / log moved on) is left running" x6untouched "$k"
done
x6ok "S06-AC-1: K03 and K04 have no status event of a stop or a resume" sh -c "[ \"\$(grep -E 'K0[34]' '$st06/status.log' | grep -ciE 'resum|stopped by the usage limit|ended')\" = 0 ]"
# AC-4: no init line; the resumed process writes none
x6ok "S06-AC-4: K05 (log without an init line) is never resumed: no run has --resume" sh -c "! grep -lx -- --resume '$S06'/args.K05.* 2>/dev/null | grep -q ."
x6ok "S06-AC-4: K06's resumed claude (exits 7, writes no init line) was started with --resume sid-K06" sh -c "grep -qx -- --resume '$S06/args.K06.2' 2>/dev/null && [ \"\$(cat '$S06/sid.K06.2')\" = sid-K06 ]"
for k in K05 K06; do
	x6ok "S06-AC-4: $k is stopped: its first process group is gone" sh -c "$(declare -f x6grp_gone x6dead x6f); S06='$S06'; x6grp_gone \"\$(x6f pg.$k)\" && x6dead \"\$(x6f child.$k)\""
	x6ok "S06-AC-4: $k: one status event names it and says it could not be resumed" test "$(x6nores_n "$k")" = 1
	x6ok "S06-AC-4: $k ends as a limit exit (start not counted)" test "$(x6evn "$k" 'stopped by the usage limit.*start not counted')" -ge 1
	x6ok "S06-AC-4: $k: no FAILED" test ! -e "$st06/node/$k/FAILED"
done
x6ok "S06-AC-4: K05 starts again by the usual path (run 2, no --resume), both starts are start 1 of 2" sh -c "[ '$(x6runs K05)' = 2 ] && ! grep -qx -- --resume '$S06/args.K05.2' && [ \"\$(grep -c 'started K05 .*start 1 of 2' '$st06/status.log')\" = 2 ]"
x6ok "S06-AC-4: K06 starts again by the usual path (run 3, no --resume), its starts are not used up: both starts are start 1 of 2" sh -c "[ '$(x6runs K06)' = 3 ] && ! grep -qx -- --resume '$S06/args.K06.3' && [ \"\$(grep -c 'started K06 .*start 1 of 2' '$st06/status.log')\" = 2 ]"
x6ok "S06-AC-4: after the usual restart K05 and K06 end by the usual path with QUESTION.md and starts 1" sh -c "[ \"\$(cat '$st06/node/K05/starts')\" = 1 ] && [ \"\$(cat '$st06/node/K06/starts')\" = 1 ] && [ -e '$st06/node/K05/QUESTION.md' ] && [ -e '$st06/node/K06/QUESTION.md' ]"
# AC-3: the end of a resumed session is reported by the usual path
rm -f "$S06/hold.K01" "$S06/hold.issue-46"
touch "$S06/go"; rm -f "$S06/hold.K02"
x6wait 10 sh -c "[ \"\$(grep -cE 'session K01 ended \(rc 0\) with QUESTION.md|session K02 ended \(rc 0\) with QUESTION.md|triage of #46 ended \(rc 0\) with QUESTION.md' '$st06/status.log')\" = 3 ]"
x6ok "S06-AC-3: K01's resumed session ends by the usual path (rc 0, QUESTION.md)" test "$(x6evn K01 'session K01 ended \(rc 0\) with QUESTION.md')" = 1
x6ok "S06-AC-3: K02's resumed session ends by the usual path (rc 0, QUESTION.md)" test "$(x6evn K02 'session K02 ended \(rc 0\) with QUESTION.md')" = 1
x6ok "S06-AC-3: the resumed triage session ends by the usual path (rc 0, QUESTION.md)" test "$(x6evn issue-46 'triage of #46 ended \(rc 0\) with QUESTION.md')" = 1
x6ok "S06-AC-3: K02 is not resumed a second time after its resumed run ended" test "$(x6runs K02)" = 2
kill "$lp06"; wait "$lp06" 2>/dev/null
for f in "$S06"/pg.* "$S06"/pg2.* "$S06"/child.*; do [ -e "$f" ] || continue; kill -KILL -- "-$(cat "$f")" 2>/dev/null; kill -KILL "$(cat "$f")" 2>/dev/null; done

loop_end
