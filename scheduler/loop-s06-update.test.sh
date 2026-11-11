#!/bin/bash
# S06: an idle update session (PR #101) is resumed after the usage limit. Part of the end-to-end test of scheduler/loop.sh.
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"   # the runner runs *.test.sh with sh, except loop.test.sh
. "$(dirname "$0")/testdata/lib/loop-prelude.sh"
. "$src/testdata/lib/loop-s06.sh"

# The end of the run in loop-s06.test.sh, on its own: the throttle is open, the triage is gone, and the bot's CONFLICTING spec PR #101
# is the only task: its update session runs, writes the rejection (resetsAt 300 s in the past) and is resumed. The fakes and the
# files they write are those of loop-s06.test.sh (see its header).
. "$src/testdata/lib/loop-s06-main.sh"
echo "[]" >"$S06/issues.json"
for i in 1 2 3 4 5 6; do mkdir -p "$st06/node/K0$i"; touch "$st06/node/K0$i/FAILED"; done   # the nodes are the subject of loop-s06.test.sh
touch "$S06/hold.pr-101" "$S06/arm"
echo "101 spec/u1 abc123 true CONFLICTING" >"$S06/open.tsv"
x6keys=""
NOODLEBOT_DATA=$data06 PATH=$tmp/bin06:$PATH SCHED_REPORT=0 SCHED_TICK=1 SCHED_POLL=0.2 \
	bash "$nb06/scheduler/loop.sh" o/s06 >>"$tmp/s06-loop.out" 2>&1 &
pids+=("$!"); lp06=$!
echo "101 spec/u1 abc123 true CONFLICTING" >"$S06/open.tsv"
x6wait 20 x6have resumed-up.pr-101
wait_ticks 2 "$st06"
k=pr-101
x6ok "S06 (harness): the update session ran and was resumed" x6have up.pr-101 args.pr-101.2
x6ok "S06-AC-5: once the throttle is open, the update session (PR #101) is resumed" x6have args.pr-101.2
x6ok "S06-AC-2: pr-101 (update session): claude runs again with --resume <the id of the log's last init line> and the original options and unattended.md" x6args_ok "$k"
x6ok "S06-AC-2: pr-101 (update session): the resume prompt says the usage limit stopped it and has reset, background agents and commands were killed; check, re-dispatch, carry on" x6prompt_says "$S06/prompt.$k.2"
x6ok "S06-AC-2: pr-101 (update session): its old claude and process group are gone; the new process is the session (S06-AC-3)" x6run_ok "$k"
x6ok "S06-AC-2: pr-101 (update session): same worktree, same changes and HEAD, no leftover patch" x6wt_ok "$k"
x6ok "S06-AC-2: pr-101 (update session): the new output is appended to the same session.jsonl" x6log_ok "$k"
x6ok "S06-AC-2: pr-101 (update session): starts unchanged (1), no new start" x6starts_ok "$k"
x6ok "S06-AC-2: pr-101 (update session): one status event names it and the reset time" test "$(x6res_n "$k")" = 1
rm -f "$S06/hold.pr-101"
x6wait 8 sh -c "grep -qE 'update of PR #101 ended \(rc 0\)' '$st06/status.log'"
x6ok "S06-AC-3: the resumed update session ends by the usual path (rc 0)" test "$(x6evn pr-101 'update of PR #101 ended \(rc 0\)')" = 1
kill "$lp06"; wait "$lp06" 2>/dev/null
for f in "$S06"/pg.* "$S06"/pg2.* "$S06"/child.*; do [ -e "$f" ] || continue; kill -KILL -- "-$(cat "$f")" 2>/dev/null; kill -KILL "$(cat "$f")" 2>/dev/null; done

loop_end
