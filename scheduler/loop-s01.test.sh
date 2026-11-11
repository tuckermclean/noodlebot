#!/bin/bash
# S01: a session whose PR is done is stopped. Part of the end-to-end test of scheduler/loop.sh.
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"   # the runner runs *.test.sh with sh, except loop.test.sh
. "$(dirname "$0")/testdata/lib/loop-prelude.sh"
. "$src/testdata/lib/loop-fakes.sh"

# ---- S01: a session whose PR is done is stopped (merged, or closed without merging) ----
# Nodes B01..B07 (no deps) in their own remote. Every claude session runs until it is stopped and
# starts a child (sleep) of its own, recording the child's pid in $S01/child.<ID>.<run>; a session's
# process group id is the pid in its session.pid (sessions run under setsid). The fake gh answers
# --state merged ("<number> <branch>"), --state open (branches) and --state closed from $S01/*:
# closed.tsv holds "<number> <branch> <closed time, epoch seconds> <1 if merged>" (merged PRs are
# listed too, as on GitHub); with --json and no -q it prints the JSON array (number, headRefName,
# closedAt, mergedAt, state); with -q it applies the forms `.[] | "text \(.field) \(.field // "x")
# \(.field != null)"` and `.[].field`. closed.fail makes the closed query fail.
#   B01 merged while running (#11)             B02 closed unmerged while running (#12)
#   B03 closed (#13) before its session began  B04 closed (#14) while an open PR (#15) exists
#   B05 control; closed (#16) only in the failing-query phase
#   B06 merged (#17) while the loop is down: the next loop takes the session over
s01ok() { local name=$1; shift; if "$@"; then pass "$name"; else fail "$name"; fi; }
S01=$tmp/s01; export S01
mkdir -p "$S01" "$tmp/bin4" "$tmp/nb4/scheduler" "$tmp/nb4/plugin"
: >"$S01/merged.tsv"; : >"$S01/open.txt"; : >"$S01/closed.tsv"
cp "$src"/loop.sh "$src"/ready.py "$src"/release-markers.sh "$src"/run-session.sh "$src"/unattended.md \
	"$src"/issues.py "$src"/unattended-triage.md "$src"/status.sh "$src"/report.py "$src"/usage.py "$tmp/nb4/scheduler/"
git init -q -b main "$tmp/work4"; mkdir -p "$tmp/work4/docs"
{ echo 'nodes:'; for i in 1 2 3 4 5 6 7; do echo "  - {id: B0$i, name: n$i, deps: []}"; done; } >"$tmp/work4/docs/graph.yaml"
git -C "$tmp/work4" add -A && git -C "$tmp/work4" -c user.name=t -c user.email=t@t commit -q -m init
git clone -q --bare "$tmp/work4" "$tmp/remote4.git"
data4=$tmp/data4 state=$tmp/data4/state/sc wt4=$tmp/data4/worktrees/sc
mkdir -p "$data4/repos" "$state/node/B07"
git clone -q "$tmp/remote4.git" "$data4/repos/sc"
touch "$state/node/B07/FAILED"   # keeps B07 from starting until the failing-query phase
cat >"$tmp/bin4/gh" <<'EOF'
#!/bin/sh
case " $* " in
*" --state merged "*) echo >>"$S01/polls"; cat "$S01/merged.tsv" ;;
*" --state open "*) cat "$S01/open.txt" ;;
*" --state closed "*)
	if [ -e "$S01/closed.fail" ]; then echo "fake-closed-failure" >&2; exit 1; fi
	exec python3 -I "$S01/closed.py" "$@" ;;
*"/issues?labels=noodlebot"*) echo '[]' ;;
esac
exit 0
EOF
write_closed_py "$S01/closed.py"
cat >"$tmp/bin4/claude" <<'EOF'
#!/bin/sh
id=${2##* }
n=$(( $(cat "$S01/runs.$id" 2>/dev/null || echo 0) + 1 )); echo $n >"$S01/runs.$id"
mkdir -p "out/node/$id" && echo brief >"out/node/$id/brief.md"
sleep 300 & echo $! >"$S01/child.$id.$n"
while :; do sleep 0.2; done
EOF
chmod +x "$tmp/bin4/gh" "$tmp/bin4/claude"
s01_cleanup() {
	local f
	for f in "$state"/node/*/session.pid; do [ -e "$f" ] && kill -KILL -- "-$(cat "$f")" 2>/dev/null; done
	for f in "$S01"/child.*; do [ -e "$f" ] && kill -KILL "$(cat "$f")" 2>/dev/null; done
	return 0
}
extra_cleanup() { s01_cleanup; }
# ev <node> <PR number>: status.log events that name the node and the PR and say "stop".
ev() { grep -i stop "$state/status.log" | grep -F "$1" | grep -cE "#$2([^0-9]|\$)"; }
evis() { [ "$(ev "$1" "$2")" = "$3" ]; }
countis() { [ "$(count "$1")" = "$2" ]; }
loop4() {
	NOODLEBOT_DATA=$data4 PATH=$tmp/bin4:$PATH SCHED_REPORT=0 SCHED_THROTTLE=0 SCHED_TICK=1 SCHED_POLL=0.2 \
		bash "$tmp/nb4/scheduler/loop.sh" o/sc >>"$tmp/s01-loop.out" 2>&1 &
	pids+=("$!"); lp4=$!
}
s01_started() { [ "$(grep -cE 'started B0[1-6] ' "$state/status.log" 2>/dev/null)" -ge "$1" ]; }
s01runs() { cat "$S01/runs.$1" 2>/dev/null || echo 0; }
pg() { cat "$state/node/$1/session.pid"; }
loop4; loop1s=$lp4
s01ok "S01 setup: six sessions run, each with a child of its own" waitf 20 sh -c "[ \$(ls '$S01'/child.B0[1-6].1 2>/dev/null | wc -l) = 6 ]"
p1=$(pg B01) p2=$(pg B02) p3=$(pg B03) p4=$(pg B04) p5=$(pg B05) p6=$(pg B06)
c1=$(cat "$S01/child.B01.1" 2>/dev/null) c2=$(cat "$S01/child.B02.1" 2>/dev/null)
s01ok "S01 setup: a session's child is in the session's process group" sh -c "[ \"\$(ps -o pgid= -p '$c1' | tr -d ' ')\" = '$p1' ]"
# the loop has logged the start of all six sessions (the old fixed sleep of 2 s let it settle)
wait_until 5 s01_started 6
now=$(date +%s)
# open.txt first: the loop reads both files in one tick, and B04's open PR must be there when its closed PR is
echo node/B04-n4 >"$S01/open.txt"
wait_polls "$S01/polls" "$(polls "$S01/polls")" 2   # two ticks that read open.txt, so none sees #14 closed without its open PR
printf '13 node/B03-n3 %s 0\n14 node/B04-n4 %s 0\n' $((now - 3600)) "$now" >"$S01/closed.tsv"
wait_ticks 3
s01ok "S01-AC-3: a PR closed before the session started does not stop it" grp_up "$p3"
s01ok "S01-AC-3: a closed PR does not stop the session of a node that also has an open PR" grp_up "$p4"
s01ok "S01-AC-3: nodes with no PR are untouched" grp_up "$p5"
s01ok "S01-AC-3: no stop event for them" sh -c "! grep -i stop '$state/status.log' | grep -qE 'B0[345]'"

echo "11 node/B01-n1" >>"$S01/merged.tsv"; printf '11 node/B01-n1 %s 1\n' "$(date +%s)" >>"$S01/closed.tsv"
s01ok "S01-AC-1: a session whose PR merged while it ran: its process group is gone within a tick" waitf 4 grp_gone "$p1"
s01ok "S01-AC-1: and its child with it" waitf 2 dead "$c1"
s01ok "S01-AC-1: one status-log event names the node and the merged PR" waitf 3 evis B01 11 1
s01ok "S01-AC-1: its evidence is archived to state/archive/B01-out" waitf 3 test -f "$state/archive/B01-out/brief.md"
s01ok "S01-AC-1: its worktree is removed" waitf 3 test ! -d "$wt4/B01"
m1=$(polls "$S01/polls")   # its "not repeated" checks are made below, three ticks on

printf '12 node/B02-n2 %s 0\n' "$(date +%s)" >>"$S01/closed.tsv"
s01ok "S01-AC-2: a session whose PR was closed unmerged while it ran: its process group is gone within a tick" waitf 4 grp_gone "$p2"
s01ok "S01-AC-2: and its child with it" waitf 2 dead "$c2"
s01ok "S01-AC-2: one status-log event names the node and the closed PR" waitf 3 evis B02 12 1
s01ok "S01-AC-2: its FAILED marker names the closed PR" waitf 3 sh -c "head -n1 '$state/node/B02/FAILED' | grep -qE '#12([^0-9]|\$)'"
s01ok "S01-AC-2: its worktree remains" test -d "$wt4/B02"
s01ok "S01-AC-2: its branch remains" git -C "$data4/repos/sc" rev-parse --verify -q node/B02-n2
wait_polls "$S01/polls" "$m1" 3
s01ok "S01-AC-1: the event is not repeated on later ticks" test "$(ev B01 11)" = 1
s01ok "S01-AC-1: the merged node is not started again" test "$(s01runs B01)" = 1
wait_ticks 3
s01ok "S01-AC-2: the event is not repeated on later ticks" test "$(ev B02 12)" = 1
s01ok "S01-AC-2: it is not started on later ticks" test "$(s01runs B02)" = 1
rm -f "$state/node/B02/FAILED"
s01ok "S01-AC-2: after FAILED is deleted it starts again, as start 1 of 2" waitf 4 countis 'started B02 .*start 1 of 2' 2
m2b=$(polls "$S01/polls")   # the two checks on the new session are made below, three ticks on

wait_polls "$S01/polls" "$m2b" 3
s01ok "S01-AC-2: the new session is not stopped for the PR closed before it began" sh -c "[ \"\$(cat '$S01/runs.B02')\" = 2 ] && kill -0 \"\$(cat '$state/node/B02/session.pid')\""
s01ok "S01-AC-2: and no second FAILED is written" test ! -e "$state/node/B02/FAILED"

# A session taken over after a restart: the loop is down while B06's PR merges.
kill "$loop1s"; wait "$loop1s" 2>/dev/null
sleep 0.5   # nothing to observe: the loop is gone; the session must still be alive a moment after it
c6=$(cat "$S01/child.B06.1" 2>/dev/null)
s01ok "S01 setup: stopping the loop leaves B06's session running" grp_up "$p6"
echo "17 node/B06-n6" >>"$S01/merged.tsv"; printf '17 node/B06-n6 %s 1\n' "$(date +%s)" >>"$S01/closed.tsv"
loop4; loop2s=$lp4
s01ok "S01-AC-1: a taken-over session whose PR merged: its process group is gone within a tick" waitf 4 grp_gone "$p6"
s01ok "S01-AC-1: (taken over) and its child with it" waitf 2 dead "$c6"
s01ok "S01-AC-1: (taken over) one status-log event names the node and the merged PR" waitf 3 evis B06 17 1
s01ok "S01-AC-1: (taken over) its evidence is archived to state/archive/B06-out" waitf 3 test -f "$state/archive/B06-out/brief.md"
s01ok "S01-AC-1: (taken over) its worktree is removed" waitf 3 test ! -d "$wt4/B06"
m6=$(polls "$S01/polls")
wait_polls "$S01/polls" "$m6" 2
s01ok "S01-AC-1: (taken over) the event is not repeated" test "$(ev B06 17)" = 1
s01ok "S01-AC-3: after the restart the sessions of B03, B04 and B05 still run" bash -c "$(declare -f grp_gone grp_up); grp_up $p3 && grp_up $p4 && grp_up $p5"

kill "$loop2s"; wait "$loop2s" 2>/dev/null
s01_cleanup

loop_end
