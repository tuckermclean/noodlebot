#!/bin/bash
# L01: the label step runs once at the start. Part of the end-to-end test of scheduler/loop.sh.
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"   # the runner runs *.test.sh with sh, except loop.test.sh
. "$(dirname "$0")/testdata/lib/loop-prelude.sh"

# ---- L01: the label step (labels.py ensure) runs once when the loop starts, never on a tick ----
# A fresh scheduler checkout with labels.py (copied only when it exists, so a missing labels.py
# fails the checks below instead of the harness) and its own fakes: gh logs "merged" for every PR
# poll (one per tick) and "labels <args>" for every call on the repository's labels, in order.
# The file $L01_FAIL, when it exists, makes every labels call fail with "fake-label-failure".
nb3=$tmp/nb3
mkdir -p "$nb3/scheduler" "$nb3/plugin" "$tmp/bin3"
cp "$src"/loop.sh "$src"/ready.py "$src"/release-markers.sh "$src"/run-session.sh "$src"/unattended.md \
	"$src"/issues.py "$src"/unattended-triage.md "$src"/status.sh "$src"/report.py "$src"/usage.py "$nb3/scheduler/"
[ -f "$src/labels.py" ] && cp "$src/labels.py" "$nb3/scheduler/"
cat >"$tmp/bin3/gh" <<'EOF'
#!/bin/sh
case " $* " in
*" --state merged "*) echo merged >>"$L01_LOG"; echo "1 node/A01-first-node" ;;
*"/issues?labels=noodlebot"*) echo '[]' ;;
*" repos/"*"/labels"*)
	echo "labels $*" >>"$L01_LOG"; cat >/dev/null
	if [ -e "$L01_FAIL" ]; then echo "fake-label-failure" >&2; exit 1; fi
	echo '[{"name": "noodlebot"}, {"name": "noodlebot-triaged"}, {"name": "noodlebot-status"}, {"name": "noodlebot-unit"}]' ;;
esac
exit 0
EOF
cat >"$tmp/bin3/claude" <<'EOF'
#!/bin/sh
echo "$2" >>"$L01_CLAUDE"
echo "Q1: x" >"$L01_STATE/node/${2##* }/QUESTION.md"
exit 0
EOF
chmod +x "$tmp/bin3/gh" "$tmp/bin3/claude"
# l01_run <name> <fail|ok>: a loop for o/<name> with a 1 s tick, running until three ticks have
# polled GitHub and a ready node has started (at most 15 s).
l01_run() {
	local name=$1 mode=$2 lp root=$tmp/data3
	state=$root/state/$name
	export L01_LOG=$tmp/l01-$name.log L01_CLAUDE=$tmp/l01-claude-$name.log L01_STATE=$state L01_FAIL=$tmp/l01-fail-$name
	: >"$L01_LOG"; : >"$L01_CLAUDE"
	[ "$mode" = fail ] && : >"$L01_FAIL"
	mkdir -p "$root/repos" "$state/node/A02" "$state/node/A03" "$state/node/A04" "$state/node/A05"
	touch "$state/node/A03/FAILED" "$state/node/A04/FAILED" "$state/node/A05/FAILED"
	git clone -q "$tmp/remote.git" "$root/repos/$name"
	NOODLEBOT_DATA=$root PATH=$tmp/bin3:$PATH SCHED_REPORT=0 SCHED_TICK=1 SCHED_POLL=0.2 bash "$nb3/scheduler/loop.sh" "o/$name" >"$tmp/l01-$name.out" 2>&1 &
	lp=$!; pids+=("$lp"); l01_lp=$lp
	wait_until 15 l01_polled 3
	wait_until 5 l01_polled 4   # one more tick, as the fixed sleep of 1 s was
}
# l01_polled <n>: the loop has polled GitHub for merged PRs n times (one per tick) and started a ready node.
l01_polled() { [ "$(grep -c merged "$L01_LOG")" -ge "$1" ] && grep -q 'node A02' "$L01_CLAUDE"; }
l01_stop() {
	touch "$HOME/STOP-$1"
	wait_until 5 l01_gone "$l01_lp"
}
l01_gone() { ! kill -0 "$1" 2>/dev/null; }
l01_run pl ok
ok "L01-AC-4: the loop ticked at least three times (it polled GitHub for merged PRs)" test "$(grep -c merged "$L01_LOG")" -ge 3
ok "L01-AC-4: the label step ran once: one listing of o/pl's labels over all those ticks" test "$(grep -c '^labels .*o/pl/labels' "$L01_LOG")" = 1
ok "L01-AC-4: and it ran at the start, before the first tick" sh -c "[ \"\$(head -n1 '$L01_LOG' | cut -c1-6)\" = labels ]"
ok "L01-AC-4: with every label present, the label step wrote nothing" sh -c "grep -q '^labels' '$L01_LOG' && ! grep -E '^labels .*(POST|PATCH|DELETE)' '$L01_LOG'"
l01_stop pl
# AC-5: the label step fails (gh fails on every labels call).
l01_run pf fail
ok "L01-AC-5: the failing label step ran once, not on later ticks" test "$(grep -c '^labels .*o/pf/labels' "$L01_LOG")" = 1
ok "L01-AC-5: the loop still ticked (it polled GitHub for merged PRs)" test "$(grep -c merged "$L01_LOG")" -ge 3
ok "L01-AC-5: and started ready work" within 5 "started A02 \(second-node\)"
ok "L01-AC-5: the failure is one status-log event" test "$(grep -ci 'label' "$state/status.log")" = 1
ok "L01-AC-5: its stderr is in report.log" grep -q fake-label-failure "$state/report.log"
l01_stop pf

loop_end
