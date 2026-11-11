#!/bin/bash
# G02: an update that commits locally and ends without rc 0 (230..232). Part of the end-to-end test of scheduler/loop.sh (fixture: testdata/lib/loop-g02.sh).
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"   # the runner runs *.test.sh with sh, except loop.test.sh
. "$(dirname "$0")/testdata/lib/loop-prelude.sh"
. "$src/testdata/lib/loop-g02.sh"

# The state the main run is in when it comes to these cases: the throttle open (an allowed window), the PRs of the main part not wanting an update.
g02_rl 0.01 $(($(date +%s) + 7200))
g02_prs 201 MERGEABLE; g02_prs 205 MERGEABLE
# G02-AC-2 (third review, finding 1): an update that commits in its pr-<N> worktree and ends without rc 0 is
# started again (its own local commit is not a node's unpushed work), and its second end without rc 0 writes
# FAILED. The fake claude here is a wrapper that makes a local commit in its cwd on the run named by
# $G02_GD/commit.<key>.<run>, then runs the fake above. 230: node PR, rc 1 twice. 231: node PR, the first run
# ends with a limit exit (no start used). 232: a spec PR (G01-AC-6), rc 1 twice.
sed -i 's/ [A-Z]*$/ MERGEABLE/' "$G02_GD/prs.tsv"
g02g fetch -q "$G02/remote.git" main && g02g reset -q --hard FETCH_HEAD
printf '  - {id: N20, name: tau, deps: []}\n  - {id: N21, name: upsilon, deps: []}\n  - {id: N22, name: chi, deps: []}\n' >>"$G02/work/docs/graph.yaml"
g02g commit -q -a -m "graph: N20, N21, N22" && g02g push -q "$G02/remote.git" main
for g02_i in node/N20-tau node/N21-upsilon node/N22-chi spec/s2 spec/s3; do
	g02g checkout -q -b "$g02_i" main && g02g commit -q --allow-empty -m "branch $g02_i" && g02g push -q "$G02/remote.git" "$g02_i"; g02g checkout -q main
done
mkdir -p "$G02/bin2"
cat >"$G02/bin2/claude" <<'EOT'
#!/bin/sh
k=${2##* }; n=$(( $(cat "$G02_GD/runs.$k" 2>/dev/null || echo 0) + 1 ))
if [ -e "$G02_GD/commit.$k.$n" ]; then
	echo m >"local-$k-$n.txt"; git add "local-$k-$n.txt"; git -c user.name=t -c user.email=t@t commit -q -m "local commit of run $n"
fi
exec "$G02_GD/../bin/claude" "$@"
EOT
chmod +x "$G02/bin2/claude"
g02c_loop() {   # g02_loop with the committing wrapper first on PATH: g02c_loop <SCHED_MAX>
	rm -f "$HOME/STOP-g02"
	NOODLEBOT_DATA=$g02_data PATH=$G02/bin2:$G02/bin:$PATH SCHED_REPORT=0 SCHED_TICK=1 SCHED_POLL=0.2 SCHED_MAX=$1 \
		bash "$G02/nb/scheduler/loop.sh" o/g02 >>"$G02/loop.out" 2>&1 &
	pids+=("$!"); g02_lp=$!
}
printf '230 node/N20-tau app/noodlebot true CONFLICTING\n231 node/N21-upsilon app/noodlebot true CONFLICTING\n232 spec/s2 app/noodlebot true CONFLICTING\n' >>"$G02_GD/prs.tsv"
touch "$G02_GD/commit.230.1" "$G02_GD/commit.231.1" "$G02_GD/commit.232.1" "$G02_GD/limit.231.1"
echo 1 >"$G02_GD/rc.230.1"; echo 1 >"$G02_GD/rc.230.2"; echo 1 >"$G02_GD/rc.231.2"; echo 1 >"$G02_GD/rc.231.3"
echo 1 >"$G02_GD/rc.232.1"; echo 1 >"$G02_GD/rc.232.2"
touch "$G02_GD/hold.231.2"
g02c_loop 0
ok "G02-AC-2: the update of 230 starts, in worktrees/<name>/pr-230" waitf 10 grep -qF "nupd 230 run 1 /noodlebot:node --update 230 | $g02_wt/pr-230 |" "$G02_GD/claude.log"
ok "G02-AC-2: the update of 232 starts, in worktrees/<name>/pr-232" waitf 10 grep -qF "supd 232 run 1 /noodlebot:triage --update 232 | $g02_wt/pr-232 |" "$G02_GD/claude.log"
ok "G02-AC-2: the first run of 230 committed in its worktree" waitf 5 sh -c "git -C '$g02_wt/pr-230' log --format=%s | grep -q 'local commit of run 1'"
ok "G02-AC-2: a node-PR update (230) that committed locally and ended rc 1 is started again" waitf 12 g02_runsis 230 2
ok "G02-AC-2: that second start of 230 is start 2 of 2" waitf 5 g02_evis 230 'start 2 of 2' 1
ok "G02-AC-2: the second end of 230 without rc 0 writes FAILED" waitf 8 test -e "$state/pr/230/FAILED"
wait_ticks 3
ok "G02-AC-2: with FAILED there, 230 is not started a third time" g02_runsis 230 2
ok "G02-AC-2: a node-PR update (231) whose first run committed locally and ended with a limit exit is started again" waitf 12 g02_runsis 231 2
rm -f "$G02_GD/hold.231.2"
ok "G02-AC-2: the limit exit used no start: 231 is started a third time (start 2 of 2)" waitf 12 g02_runsis 231 3
ok "G02-AC-2: the second end of 231 without rc 0 writes FAILED" waitf 8 test -e "$state/pr/231/FAILED"
ok "G02-AC-1: a spec-PR update (232) that committed locally and ended rc 1 is started again (G01-AC-6)" waitf 12 g02_runsis 232 2
ok "G02-AC-1: the second end of 232 without rc 0 writes FAILED" waitf 8 test -e "$state/pr/232/FAILED"
g02_stop
g02_prs 230 MERGEABLE; g02_prs 231 MERGEABLE; g02_prs 232 MERGEABLE

loop_end
