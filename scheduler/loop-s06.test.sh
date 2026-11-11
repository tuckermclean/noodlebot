#!/bin/bash
# S06: idle sessions resumed after the usage limit. Part of the end-to-end test of scheduler/loop.sh.
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"   # the runner runs *.test.sh with sh, except loop.test.sh
. "$(dirname "$0")/testdata/lib/loop-prelude.sh"
. "$src/testdata/lib/loop-s06.sh"

# ---- S06: a session the usage limit left idle is resumed (claude -p --resume), or restarted when that is not possible ----
# A loop of its own (o/s06, 1 s tick, the real throttle) over its own remote: nodes K01..K06 (no deps), the owner's
# issue #46 (triage) and, once the triage has ended, the bot's CONFLICTING spec PR #101 (update). The fake claude is
# keyed by its working directory (K01.., issue-46, pr-101) and counts its runs in $S06/runs.<key>; it records, per run
# <n>: the argument lines (args), the prompt after -p, the id after --resume (sid), the text after
# --append-system-prompt (append), its pwd, `git status --porcelain` (status) and HEAD (head). A first run writes
# its dirt (base.txt edited, u.<key>.txt new) and a child `sleep` (pids in pg.<key>, child.<key>), writes a
# system/init line (session id sid-<key>), waits for $S06/arm, then writes the lines below to the log and sleeps:
#   K01 and issue-46 and pr-101: a rate_limit_event with status rejected, resetsAt 300 s in the past.
#   K02: two init lines (sid-K02-old, then sid-K02), the rejection, then a result naming the usage limit.
#   K03: the rejection with resetsAt 5 s in the past (under 2 minutes).  K04: the rejection, then further lines.
#   K05: no init line at all, the rejection.  K06: init line, the rejection.
# A run with --resume writes an init line and a marker line, then waits while $S06/hold.<key> exists:
#   K01, issue-46, pr-101: ends (QUESTION.md for the node and the issue). K02: writes the same rejection and a
#   result again and waits for $S06/go. K06: exits 7 at once and writes nothing.
# A later run without --resume (K05 run 2, K06 run 3): QUESTION.md. The throttle is held (a rejected five_hour window
# in another repository's log, resetting in the future) from before the sessions write their rejection until the
# check of S06-AC-5, then released by a later allowed window.
. "$src/testdata/lib/loop-s06-main.sh"
touch "$S06/hold.K01" "$S06/hold.K02" "$S06/hold.issue-46" "$S06/hold.pr-101"
x6keys="K01 K02 K03 K04 K05 K06 issue-46"
NOODLEBOT_DATA=$data06 PATH=$tmp/bin06:$PATH SCHED_REPORT=0 SCHED_TICK=1 SCHED_POLL=0.2 \
	bash "$nb06/scheduler/loop.sh" o/s06 >>"$tmp/s06-loop.out" 2>&1 &
pids+=("$!"); lp06=$!
x6wait 20 x6have up.K01 up.K02 up.K03 up.K04 up.K05 up.K06 up.issue-46
x6ok "S06 (harness): the six nodes and the triage session are running" x6have up.K01 up.K02 up.K03 up.K04 up.K05 up.K06 up.issue-46
# the throttle holds, then the sessions write their rejections
printf '{"type":"rate_limit_event","rate_limit_info":{"status":"rejected","unifiedWindows":{"five_hour":{"utilization":1.0,"resetsAt":%s,"status":"rejected"}}}}\n' $(($(date +%s) + 3600)) >"$data06/state/other/node/Z01/session.jsonl"
x6wait 8 grep -q 'throttle engaged' "$st06/status.log"
x6ok "S06 (harness): the throttle engages" grep -q 'throttle engaged' "$st06/status.log"
touch "$S06/arm"
x6wait 8 x6have armed.K01 armed.K02 armed.K03 armed.K04 armed.K05 armed.K06 armed.issue-46
wait_ticks 6 "$st06"
# AC-5: held
for k in $x6keys; do
	x6ok "S06-AC-5: while the throttle holds, $k (idle past its reset) is neither stopped nor resumed" x6untouched "$k"
done
printf '{"type":"rate_limit_event","rate_limit_info":{"status":"allowed","unifiedWindows":{"five_hour":{"utilization":0.01,"resetsAt":%s,"status":"allowed"},"seven_day":{"utilization":0.0,"resetsAt":%s,"status":"allowed"}}}}\n' \
	$(($(date +%s) + 7200)) $(($(date +%s) + 3 * 86400)) >>"$data06/state/other/node/Z01/session.jsonl"
x6wait 8 grep -q 'throttle released' "$st06/status.log"
x6ok "S06-AC-5 (harness): the throttle releases" grep -q 'throttle released' "$st06/status.log"
x6wait 25 x6have resumed-up.K01 resumed-up.K02 resumed-up.issue-46 resumed-up.K06 args.K05.2 args.K06.3
# K02's resumed run writes the same rejection again as soon as its hold goes (the check below, "resumed once", comes after
# the four ticks that follow it; the checks of the other resumes use the same four ticks, so they are waited for once)
rm -f "$S06/hold.K02"
x6wait 10 sh -c "[ \"\$(grep -c 'rate_limit_event' '$st06/node/K02/session.jsonl')\" = 2 ]"
wait_ticks 4 "$st06"
for k in K01 K02 issue-46; do
	case $k in issue-*) ty=triage ;; *) ty=node ;; esac
	x6ok "S06-AC-5: once the throttle releases, $k ($ty session) is resumed" x6have "args.$k.2"
	x6ok "S06-AC-2: $k ($ty session): claude runs again with --resume <the id of the log's last init line> and the original options and unattended.md" x6args_ok "$k"
	x6ok "S06-AC-2: $k ($ty session): the resume prompt says the usage limit stopped it and has reset, background agents and commands were killed; check, re-dispatch, carry on" x6prompt_says "$S06/prompt.$k.2"
	x6ok "S06-AC-2: $k ($ty session): its old claude and process group are gone; the new process is a run-session.sh, recorded in session.pid (S06-AC-3)" x6run_ok "$k"
	x6ok "S06-AC-2: $k ($ty session): same worktree, same changes and HEAD, no leftover patch" x6wt_ok "$k"
	x6ok "S06-AC-2: $k ($ty session): the new output is appended to the same session.jsonl" x6log_ok "$k"
	x6ok "S06-AC-2: $k ($ty session): starts unchanged (1), no new start, claude ran twice" x6starts_ok "$k"
	x6ok "S06-AC-2: $k ($ty session): one status event names it and the reset time" test "$(x6res_n "$k")" = 1
done
x6ok "S06-AC-3: while the resumed triage session runs, no update session is started" test "$(x6runs pr-101)" = 0
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
