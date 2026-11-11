#!/bin/bash
# S02: background work is not cut off. Part of the end-to-end test of scheduler/loop.sh.
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"   # the runner runs *.test.sh with sh, except loop.test.sh
. "$(dirname "$0")/testdata/lib/loop-prelude.sh"

# ---- S02: a session's background work is not cut off; if it still is, the start is given back ----
# Nodes C01..C05 (no deps) in their own remote, one issue (#71) for triage. The fake claude records
# CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS ("UNSET" when absent) per run in $S02/env.<key>.<run>, and per key/run:
#   C01 run 1: empty exit 0. run 2: the CLI's cut-off message on stderr, exit 0. run 3: QUESTION.md.
#   C02 run 1: empty exit 1. run 2: the cut-off message, exit 5. run 3: QUESTION.md.
#   C03 run 1: empty exit 0. run 2: other stderr text, exit 0 (no cut-off message).
#   C04 run 1: QUESTION.md (started by the second loop, which has the variable set).
#   C05 run 1: exit 1. run 2: other stderr text, exit 7 (no cut-off message).
#   #71 (triage) run 1: the cut-off message, exit 0, no QUESTION.md. run 2: QUESTION.md.
S02=$tmp/s02; export S02
mkdir -p "$S02" "$tmp/bin5" "$tmp/nb5/scheduler" "$tmp/nb5/plugin"
cp "$src"/loop.sh "$src"/ready.py "$src"/release-markers.sh "$src"/run-session.sh "$src"/unattended.md \
	"$src"/issues.py "$src"/unattended-triage.md "$src"/status.sh "$src"/report.py "$src"/usage.py "$tmp/nb5/scheduler/"
git init -q -b main "$tmp/work5"; mkdir -p "$tmp/work5/docs"
{ echo 'nodes:'; for i in 1 2 3 4 5; do echo "  - {id: C0$i, name: n$i, deps: []}"; done; } >"$tmp/work5/docs/graph.yaml"
git -C "$tmp/work5" add -A && git -C "$tmp/work5" -c user.name=t -c user.email=t@t commit -q -m init
git clone -q --bare "$tmp/work5" "$tmp/remote5.git"
data5=$tmp/data5 state=$tmp/data5/state/sd wt5=$tmp/data5/worktrees/sd
S02_STATE=$state; export S02_STATE
mkdir -p "$data5/repos" "$state/node/C04"
git clone -q "$tmp/remote5.git" "$data5/repos/sd"
touch "$state/node/C04/FAILED"   # C04 is started by the second loop
echo '[{"number": 71}]' >"$tmp/issues5.json"
printf '%s\n' 'Background tasks still running 10m after the last turn (subagent "P02 slice 6 GREEN attempt 3"); stopping them. Set CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=0 to wait indefinitely.' >"$S02/msg"
cat >"$tmp/bin5/gh" <<EOF
#!/bin/sh
echo "\$*" >>"$S02/gh.log"
case " \$* " in
*" --state merged "*) : ;;
*"/issues?labels=noodlebot"*) cat "$tmp/issues5.json" ;;
*"/events"*) echo '[{"event": "labeled", "label": {"name": "noodlebot"}, "actor": {"login": "o"}}]' ;;
*" DELETE "*"/labels/noodlebot"*) echo '[]' ;;
*"/labels"*) cat >/dev/null; echo '{}' ;;
esac
exit 0
EOF
cat >"$tmp/bin5/claude" <<'EOF'
#!/bin/sh
case "$2" in "/noodlebot:triage "*) k=71; q="$S02_STATE/issue/71/QUESTION.md" ;; *) k=${2##* }; q="$S02_STATE/node/$k/QUESTION.md" ;; esac
n=$(( $(cat "$S02/runs.$k" 2>/dev/null || echo 0) + 1 )); echo $n >"$S02/runs.$k"
echo "${CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS-UNSET}" >"$S02/env.$k.$n"
[ "$k.$n" = 71.1 ] && touch .s02-kept
case $k.$n in
C01.1) exit 0 ;;
C01.2) cat "$S02/msg" >&2; exit 0 ;;
C01.3|C02.3|C04.1|71.2) echo "Q1: x" >"$q" ;;
C02.1) exit 1 ;;
C02.2) cat "$S02/msg" >&2; exit 5 ;;
C03.1) exit 0 ;;
C03.2) echo "warning: something else" >&2; exit 0 ;;
C05.1) exit 1 ;;
C05.2) echo "warning: something else" >&2; exit 7 ;;
71.1) cat "$S02/msg" >&2; exit 0 ;;
esac
exit 0
EOF
chmod +x "$tmp/bin5/gh" "$tmp/bin5/claude"
s02runs() { cat "$S02/runs.$1" 2>/dev/null || echo 0; }
loop5() {
	env -u CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS "$@" NOODLEBOT_DATA=$data5 PATH=$tmp/bin5:$PATH SCHED_REPORT=0 SCHED_THROTTLE=0 SCHED_TICK=1 SCHED_POLL=0.2 \
		bash "$tmp/nb5/scheduler/loop.sh" o/sd >>"$tmp/s02-loop.out" 2>&1 &
	pids+=("$!"); lp5=$!
}
loop5
timeout 12 sh -c "until [ \"\$(cat '$S02/runs.C01' 2>/dev/null)\" = 3 ] && [ \"\$(cat '$S02/runs.C02' 2>/dev/null)\" = 3 ] && [ \"\$(cat '$S02/runs.71' 2>/dev/null)\" = 2 ] && [ -e '$state/node/C03/FAILED' ] && [ -e '$state/node/C05/FAILED' ]; do sleep 0.2; done"
wait_ticks 1
ok "S02-AC-1: by default every session (node and triage) has the variable in its environment, as 0" sh -c "[ -s '$S02/env.C01.1' ] && [ -s '$S02/env.71.1' ] && [ \"\$(cat '$S02'/env.*)\" = \"\$(for f in '$S02'/env.*; do echo 0; done)\" ]"
ok "S02-AC-2: a node cut off (rc 0) on its second start writes no FAILED" test ! -e "$state/node/C01/FAILED"
ok "S02-AC-2: and starts again (a third run)" test "$(s02runs C01)" = 3
ok "S02-AC-2: its start was given back: the second and the third run are both start 2 of 2" test "$(count 'started C01 .*start 2 of 2')" = 2
ok "S02-AC-2: the end is one status-log event: session, rc, background work cut off, start not counted" test "$(grep -i 'C01' "$state/status.log" | grep -i 'background' | grep -i 'not counted' | grep -c 'rc 0')" = 1
ok "S02-AC-2: that event is the only one for that end (no 'wrote FAILED', no 'may start again' for C01 run 2)" test "$(count 'session C01 ended \(rc 0\), no PR, no QUESTION.md')" = 1
ok "S02-AC-2: a node cut off with a non-zero rc writes no FAILED" test ! -e "$state/node/C02/FAILED"
ok "S02-AC-2: and starts again (a third run)" test "$(s02runs C02)" = 3
ok "S02-AC-2: its start was given back (rc 5): the second and third run are both start 2 of 2" test "$(count 'started C02 .*start 2 of 2')" = 2
ok "S02-AC-2: the end is one status-log event naming rc 5, background work cut off, start not counted" test "$(grep -i 'C02' "$state/status.log" | grep -i 'background' | grep -i 'not counted' | grep -c 'rc 5')" = 1
ok "S02-AC-2: a session with no such message ending empty twice is counted as before: FAILED" test -e "$state/node/C03/FAILED"
ok "S02-AC-2: (and it is not started a third time)" test "$(s02runs C03)" = 1 -o "$(s02runs C03)" = 2
ok "S02-AC-2: its end writes the old 2-starts-used event, not a background one" sh -c "grep -q 'session C03 ended (rc 0).*2 starts used: wrote FAILED' '$state/status.log' && ! grep -i 'C03' '$state/status.log' | grep -qi 'background'"
ok "S02-AC-2: a non-zero rc without the message is counted as before: FAILED" sh -c "[ -e '$state/node/C05/FAILED' ] && grep -q 'session C05 ended (rc 7).*2 starts used: wrote FAILED' '$state/status.log'"
ok "S02-AC-3: a triage cut off with rc 0 and no QUESTION.md does not swap its label (no DELETE of noodlebot)" sh -c "! grep -q 'DELETE.*issues/71/labels/noodlebot' '$S02/gh.log'"
ok "S02-AC-3: it is not reported done" sh -c "! grep -q 'triage of #71 done' '$state/status.log'"
ok "S02-AC-3: its worktree is kept" test -d "$wt5/issue-71"
ok "S02-AC-3: its worktree is kept, not removed and re-made (a file run 1 left there is still there)" test -e "$wt5/issue-71/.s02-kept"
ok "S02-AC-3: its start was given back: both runs are start 1 of 2" test "$(count 'started triage of #71 .*start 1 of 2')" = 2
ok "S02-AC-3: the end is one status-log event (rc 0, background work cut off, start not counted)" test "$(grep -i 'triage of #71' "$state/status.log" | grep -i 'background' | grep -ci 'not counted')" = 1
ok "S02-AC-3: and the triage is started again, then ends with its question" test "$(s02runs 71)" = 2
kill "$lp5"; wait "$lp5" 2>/dev/null
sleep 0.5   # nothing to observe: the loop is gone and nothing more may start
rm -f "$state/node/C04/FAILED"
loop5 CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS=12345
timeout 10 sh -c "until [ -s '$S02/env.C04.1' ]; do sleep 0.2; done"
ok "S02-AC-1: a value set in the loop's environment reaches the session" sh -c "[ \"\$(cat '$S02/env.C04.1')\" = 12345 ]"
kill "$lp5"; wait "$lp5" 2>/dev/null
for f in "$state"/node/*/session.pid "$state"/issue/*/session.pid; do [ -e "$f" ] && kill -KILL -- "-$(cat "$f")" 2>/dev/null; done

loop_end
