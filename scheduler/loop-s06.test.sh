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
wait_ticks 4 "$st06"   # the old fixed sleep was 4 s: the checks below of what did not happen wait that many ticks
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
# the checks made eight ticks after the resumes (K02 resumed once, K01, AC-1, AC-4, the ends of AC-3) are in loop-s06-later.test.sh
kill "$lp06"; wait "$lp06" 2>/dev/null
for f in "$S06"/pg.* "$S06"/pg2.* "$S06"/child.*; do [ -e "$f" ] || continue; kill -KILL -- "-$(cat "$f")" 2>/dev/null; kill -KILL "$(cat "$f")" 2>/dev/null; done

loop_end
