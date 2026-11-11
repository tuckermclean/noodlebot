#!/bin/bash
# S06 (review findings): a long log is resumed by its session id; a fallback whose claude exits 0 is still a limit exit. Part of the end-to-end test of scheduler/loop.sh.
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"   # the runner runs *.test.sh with sh, except loop.test.sh
. "$(dirname "$0")/testdata/lib/loop-prelude.sh"
. "$src/testdata/lib/loop-s06.sh"

# ---- S06 (review findings): a long log is resumed by its session id; a fallback whose claude exits 0 is still a limit exit ----
# A second loop of its own (o/s06b) over its own remote, reusing the helpers above with S06, st06 and nb06 pointed at it.
# Nodes L01, F01, F02, the owner's issue #47 (triage) and the bot's CONFLICTING spec PR #102 (update). Every first run
# writes its rejection (resetsAt 300 s in the past) at once and sleeps:
#   L01: a system/init line (sid-L01) at the top, ~700 KB of ordinary lines, then the rejection. Its resume ends in QUESTION.md.
#   F02: init sid-F02, the rejection; its resumed run writes no init line and exits 0 at once.
#   F01, issue-47, pr-102: no init line, the rejection; the claude exits 0 when it gets SIGTERM.
# A later run without --resume writes QUESTION.md and exits 0 (pr-102: waits while $S06/hold.pr-102 exists, then exits 0).
S06=$tmp/s06b; export S06
mkdir -p "$S06" "$tmp/bin06b" "$tmp/nb06b/scheduler" "$tmp/nb06b/plugin" "$tmp/data06b/repos"
data06b=$(cd "$tmp/data06b" && pwd -P)
nb06=$(cd "$tmp/nb06b" && pwd -P)
st06=$data06b/state/s06b wt06=$data06b/worktrees/s06b
S06_STATE=$st06; export S06_STATE
for f in "$src"/*; do case $f in *.test.sh) ;; *) [ -f "$f" ] && cp "$f" "$tmp/nb06b/scheduler/" ;; esac; done
git init -q -b main "$tmp/work06b"; mkdir -p "$tmp/work06b/docs"
{ echo 'nodes:'; for i in L01 F01 F02; do echo "  - {id: $i, name: n$i, deps: []}"; done; } >"$tmp/work06b/docs/graph.yaml"
printf 'base\n' >"$tmp/work06b/base.txt"
git -C "$tmp/work06b" add -A && git -C "$tmp/work06b" -c user.name=t -c user.email=t@t commit -q -m init
git -C "$tmp/work06b" checkout -q -b spec/u2 && echo spec >"$tmp/work06b/spec.txt" && git -C "$tmp/work06b" add -A &&
	git -C "$tmp/work06b" -c user.name=t -c user.email=t@t commit -q -m spec && git -C "$tmp/work06b" checkout -q main
git clone -q --bare "$tmp/work06b" "$tmp/remote06b.git"
git clone -q "$tmp/remote06b.git" "$data06b/repos/s06b"
echo '[{"number": 47}]' >"$S06/issues.json"; echo "102 spec/u2 abc123 true CONFLICTING" >"$S06/open.tsv"
cat >"$tmp/bin06b/gh" <<'EOF'
#!/bin/sh
case " $* " in
*" --state open "*) cat "$S06/open.tsv" ;;
*" --state merged "* | *" --state closed "*) ;;
*"/issues?labels=noodlebot"*) cat "$S06/issues.json" ;;
*"/events"*) echo '[{"event": "labeled", "label": {"name": "noodlebot"}, "actor": {"login": "o"}}]' ;;
*"/labels"*) cat >/dev/null; echo '{}' ;;
esac
exit 0
EOF
cat >"$tmp/bin06b/claude" <<'EOF'
#!/bin/sh
key=$(basename "$(pwd -P)")
n=$(( $(cat "$S06/runs.$key" 2>/dev/null || echo 0) + 1 )); echo $n >"$S06/runs.$key"
prompt= sid= app= prev=
for a in "$@"; do
	case $prev in -p) prompt=$a ;; --resume) sid=$a ;; --append-system-prompt) app=$a ;; esac
	prev=$a
done
r=$key.$n
printf '%s\n' "$@" >"$S06/args.$r"; printf '%s' "$prompt" >"$S06/prompt.$r"; printf '%s' "$app" >"$S06/append.$r"
printf '%s' "$sid" >"$S06/sid.$r"; pwd -P >"$S06/pwd.$r"
case $key in issue-*) sd=$S06_STATE/issue/${key#issue-} ;; pr-*) sd=$S06_STATE/pr/${key#pr-} ;; *) sd=$S06_STATE/node/$key ;; esac
out() { printf '%s\n' "$1"; printf '%s\n' "$1" >>"$S06/log0.$key"; }
rej() { printf '{"type":"rate_limit_event","rate_limit_info":{"status":"rejected","resetsAt":%s,"rateLimitType":"five_hour","unifiedWindows":{"five_hour":{"utilization":1.0,"resetsAt":%s,"status":"rejected"}}},"session_id":"sid-%s"}\n' "$1" "$1" "$key"; }
if [ -n "$sid" ]; then   # resumed
	echo $PPID >"$S06/pg2.$key"; touch "$S06/resumed-up.$key"
	[ $key = F02 ] && exit 0
	printf '{"type":"system","subtype":"init","session_id":"%s","resumed_run":true}\n' "$sid"
	printf '{"type":"assistant","message":{"content":[{"type":"text","text":"resumed run of %s"}]},"resumed_run":true}\n' "$key"
	while [ -e "$S06/hold.$key" ]; do sleep 0.2; done
	echo "Q1: x" >"$sd/QUESTION.md"; exit 0
fi
if [ $n -ge 2 ]; then
	touch "$S06/up.$r"
	while [ -e "$S06/hold.$key" ]; do sleep 0.2; done
	case $key in pr-*) ;; *) echo "Q1: x" >"$sd/QUESTION.md" ;; esac
	exit 0
fi
echo $PPID >"$S06/pg.$key"; sleep 300 & echo $! >"$S06/child.$key"
case $key in L01) ;; *) trap 'exit 0' TERM ;; esac
case $key in L01|F02) out "{\"type\":\"system\",\"subtype\":\"init\",\"cwd\":\"$(pwd -P)\",\"session_id\":\"sid-$key\"}" ;; esac
if [ $key = L01 ]; then
	awk 'BEGIN { for (i = 0; i < 3000; i++) printf "{\"type\":\"%s\",\"message\":{\"content\":[{\"type\":\"text\",\"text\":\"%0200d\"}]}}\n", (i % 2 ? "user" : "assistant"), i }' | tee -a "$S06/log0.$key"
fi
touch "$S06/up.$key"
r=$(( $(date +%s) - 300 )); echo $r >"$S06/reset.$key"
out "$(rej "$r")"
touch "$S06/armed.$key"
wait
EOF
chmod +x "$tmp/bin06b/gh" "$tmp/bin06b/claude"
touch "$S06/hold.L01" "$S06/hold.pr-102"
NOODLEBOT_DATA=$data06b PATH=$tmp/bin06b:$PATH SCHED_REPORT=0 SCHED_TICK=1 SCHED_POLL=0.2 \
	bash "$nb06/scheduler/loop.sh" o/s06b >>"$tmp/s06b-loop.out" 2>&1 &
pids+=("$!"); lp06b=$!
x6wait 20 x6have up.L01 up.F01 up.F02 up.issue-47
x6ok "S06 (harness, review): the three nodes and the triage session are running" x6have up.L01 up.F01 up.F02 up.issue-47
x6ok "S06 (harness, review): L01's log is over 400 KB and its only init line is at the top" sh -c "j='$st06/node/L01/session.jsonl'; [ \"\$(stat -c %s \"\$j\")\" -gt 500000 ] && [ \"\$(grep -c '\"subtype\":\"init\"' \"\$j\")\" = 1 ] && [ \"\$(grep -n '\"subtype\":\"init\"' \"\$j\" | head -1 | cut -d: -f1)\" = 1 ]"
x6wait 25 x6have resumed-up.L01 resumed-up.F02 args.F02.2
# S06-AC-2: a long log is resumed by the id of its last init line
k=L01
x6ok "S06-AC-2: L01 (log over 400 KB, init only at the top) is resumed, not restarted" x6have "args.$k.2"
x6ok "S06-AC-2: L01 (long log): claude runs again with --resume sid-L01 and the original options and unattended.md" x6args_ok "$k"
x6ok "S06-AC-2: L01 (long log): it is not restarted by the fallback: no event says it could not be resumed" test "$(x6nores_n "$k")" = 0
x6ok "S06-AC-2: L01 (long log): the new output is appended to the same session.jsonl" x6log_ok "$k"
x6ok "S06-AC-2: L01 (long log): starts unchanged (1), no new start, claude ran twice" x6starts_ok "$k"
x6ok "S06-AC-2: L01 (long log): one status event names it and the reset time" test "$(x6res_n "$k")" = 1
x6ok "S06-AC-2: L01 (long log): its old process group is gone; the new process is the session" x6run_ok "$k"
# S06-AC-4: the fallback is a limit exit whatever the exit code of the stopped claude (here 0)
x6wait 20 x6have up.F01.2 up.F02.3 up.issue-47.2 up.pr-102.2
for k in F01 F02; do
	x6ok "S06-AC-4: $k (claude exits 0 when stopped): its first process group is gone" sh -c "$(declare -f x6grp_gone x6dead x6f); S06='$S06'; x6grp_gone \"\$(x6f pg.$k)\" && x6dead \"\$(x6f child.$k)\""
	x6ok "S06-AC-4: $k (claude exits 0): one status event says it could not be resumed" test "$(x6nores_n "$k")" = 1
	x6ok "S06-AC-4: $k (claude exits 0): it ends as a limit exit (start not counted)" test "$(x6evn "$k" 'stopped by the usage limit.*start not counted')" -ge 1
	x6ok "S06-AC-4: $k (claude exits 0): no FAILED" test ! -e "$st06/node/$k/FAILED"
done
x6ok "S06-AC-4: F02 (resumed run writes no init line and exits 0) was resumed once with --resume sid-F02" sh -c "grep -qx -- --resume '$S06/args.F02.2' 2>/dev/null && [ \"\$(cat '$S06/sid.F02.2')\" = sid-F02 ]"
x6ok "S06-AC-4: F01 (exits 0 when stopped) starts again by the usual path (run 2, no --resume), both starts are start 1 of 2" sh -c "[ '$(x6runs F01)' = 2 ] && ! grep -qx -- --resume '$S06/args.F01.2' && [ \"\$(grep -c 'started F01 .*start 1 of 2' '$st06/status.log')\" = 2 ]"
x6ok "S06-AC-4: F02 (resumed run exits 0 with no init line) starts again by the usual path (run 3, no --resume), both starts are start 1 of 2" sh -c "[ '$(x6runs F02)' = 3 ] && ! grep -qx -- --resume '$S06/args.F02.3' && [ \"\$(grep -c 'started F02 .*start 1 of 2' '$st06/status.log')\" = 2 ]"
x6wait 10 sh -c "[ -e '$st06/node/F01/QUESTION.md' ] && [ -e '$st06/node/F02/QUESTION.md' ]"
x6ok "S06-AC-4: after the usual restart F01 and F02 end by the usual path with QUESTION.md and starts 1" sh -c "[ \"\$(cat '$st06/node/F01/starts')\" = 1 ] && [ \"\$(cat '$st06/node/F02/starts')\" = 1 ] && [ -e '$st06/node/F01/QUESTION.md' ] && [ -e '$st06/node/F02/QUESTION.md' ]"
# the triage session, exit 0 on SIGTERM
x6ok "S06-AC-4: triage of #47 (claude exits 0 when stopped): one status event says it could not be resumed" test "$(x6nores_n issue-47)" = 1
x6ok "S06-AC-4: triage of #47 (claude exits 0): it ends as a limit exit (start not counted)" test "$(x6evn issue-47 'stopped by the usage limit.*start not counted')" -ge 1
x6ok "S06-AC-4: triage of #47 (claude exits 0): it is not done: no 'done' event, no noodlebot-triaged label" sh -c "[ \"\$(grep -F '#47' '$st06/status.log' | grep -ciE 'triage of #47 done|noodlebot-triaged')\" = 0 ]"
x6ok "S06-AC-4: triage of #47 (claude exits 0): its worktree is kept and there is no FAILED" sh -c "[ -d '$wt06/issue-47' ] && [ ! -e '$st06/issue/47/FAILED' ]"
x6ok "S06-AC-4: triage of #47 starts again by the usual path (run 2, no --resume) and ends with QUESTION.md" sh -c "[ '$(x6runs issue-47)' = 2 ] && ! grep -qx -- --resume '$S06/args.issue-47.2' && [ -e '$st06/issue/47/QUESTION.md' ]"
# the update session, exit 0 on SIGTERM; its second run is held so that the state after the fallback can be checked
x6ok "S06 (harness, review): the update session ran, was stopped, and started again" x6have up.pr-102 up.pr-102.2
x6ok "S06-AC-4: update of PR #102 (claude exits 0 when stopped): one status event says it could not be resumed" test "$(x6nores_n pr-102)" = 1
x6ok "S06-AC-4: update of PR #102 (claude exits 0): it ends as a limit exit (start not counted)" test "$(x6evn pr-102 'stopped by the usage limit.*start not counted')" -ge 1
x6ok "S06-AC-4: update of PR #102 (claude exits 0): it is not done: the worktree is kept, the PR is not marked done, no FAILED" sh -c "[ -d '$wt06/pr-102' ] && [ ! -e '$st06/pr/102/done' ] && [ ! -e '$st06/pr/102/FAILED' ]"
x6ok "S06-AC-4: update of PR #102 starts again by the usual path (run 2, no --resume)" sh -c "[ '$(x6runs pr-102)' = 2 ] && ! grep -qx -- --resume '$S06/args.pr-102.2'"
rm -f "$S06/hold.pr-102" "$S06/hold.L01"
kill "$lp06b"; wait "$lp06b" 2>/dev/null
for f in "$S06"/pg.* "$S06"/pg2.* "$S06"/child.*; do [ -e "$f" ] || continue; kill -KILL -- "-$(cat "$f")" 2>/dev/null; kill -KILL "$(cat "$f")" 2>/dev/null; done


loop_end
