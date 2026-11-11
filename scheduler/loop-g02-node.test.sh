#!/bin/bash
# G02: the node's own worktree has the PR's branch (N13, N14). Part of the end-to-end test of scheduler/loop.sh (fixture: testdata/lib/loop-g02.sh).
[ -n "${BASH_VERSION:-}" ] || exec bash "$0" "$@"   # the runner runs *.test.sh with sh, except loop.test.sh
. "$(dirname "$0")/testdata/lib/loop-prelude.sh"
. "$src/testdata/lib/loop-g02.sh"

# The state the main run is in when it comes to these cases: the throttle open (an allowed window), the PRs of the main part not wanting an update.
g02_rl 0.01 $(($(date +%s) + 7200))
g02_prs 201 MERGEABLE; g02_prs 205 MERGEABLE
# G02-AC-1 (review finding 1 and 2): the node's own worktree still has the PR's branch checked out, and the
# node is ready (a released answer) while its update runs. N13: the worktree exists, the update ends with
# QUESTION.md (its pr-N worktree stays). N14: its worktree is detached, the update ends with rc 0.
# Earlier PRs of this block are made MERGEABLE so only these two PRs get updates.
sed -i 's/ [A-Z]*$/ MERGEABLE/' "$G02_GD/prs.tsv"
g02g fetch -q "$G02/remote.git" main && g02g reset -q --hard FETCH_HEAD   # main has moved on the remote (g02_mvref)
printf '  - {id: N13, name: omicron, deps: []}\n  - {id: N14, name: pi, deps: []}\n' >>"$G02/work/docs/graph.yaml"
g02g commit -q -a -m "graph: N13, N14" && g02g push -q "$G02/remote.git" main
for g02_i in 13:omicron 14:pi; do
	g02g checkout -q -b "node/N${g02_i%%:*}-${g02_i#*:}" main && g02g commit -q --allow-empty -m "node ${g02_i%%:*}" &&
		g02g push -q "$G02/remote.git" "node/N${g02_i%%:*}-${g02_i#*:}"; g02g checkout -q main
done
printf '213 node/N13-omicron app/noodlebot true CONFLICTING\n214 node/N14-pi app/noodlebot true CONFLICTING\n' >>"$G02_GD/prs.tsv"
git -C "$g02_data/repos/g02" fetch -q origin
mkdir -p "$g02_wt"
git -C "$g02_data/repos/g02" worktree add -q -b node/N13-omicron "$g02_wt/N13" origin/node/N13-omicron
git -C "$g02_data/repos/g02" worktree add -q --detach "$g02_wt/N14" origin/main   # N14: its worktree is there, not on the PR branch
for g02_i in N13 N14; do
	mkdir -p "$state/node/$g02_i"
	echo "Q: x" >"$state/node/$g02_i/QUESTION.md"; echo "A: y" >"$state/node/$g02_i/ANSWER.md"
done
touch "$G02_GD/hold.213" "$G02_GD/hold.214" "$G02_GD/question.213.1"
g02_loop 0
ok "G02-AC-1: a node PR whose node worktree has the branch checked out gets its update (PR 213)" waitf 10 g02_runsis 213 1
waitf 5 grep -qF "nupd 213 run 1 /noodlebot:node --update 213 | $g02_wt/pr-213 | node/N13-omicron" "$G02_GD/claude.log"   # setup: the log line is written just after the run is counted
ok "G02-AC-1: it runs in worktrees/<name>/pr-213 on the PR's branch, though worktrees/<name>/N13 had it" grep -qF "nupd 213 run 1 /noodlebot:node --update 213 | $g02_wt/pr-213 | node/N13-omicron" "$G02_GD/claude.log"
ok "G02-AC-1: another node PR (214, its worktree detached) gets its update" waitf 10 g02_runsis 214 1
wait_ticks 3
ok "G02-AC-1: the node's session (N13, listed by ready.py as a resume) does not start while its update runs" sh -c "! grep -qE '^node N13 ' '$G02_GD/claude.log'"
ok "G02-AC-1: the node's session (N14, listed by ready.py as a resume) does not start while its update runs" sh -c "! grep -qE '^node N14 ' '$G02_GD/claude.log'"
rm -f "$G02_GD/hold.213" "$G02_GD/hold.214"
ok "G02-AC-1: when its update has ended, the node's session (N14) starts" waitf 10 g02_runsis N14 1
ok "G02-AC-1: when its update has ended with QUESTION.md, the node's session (N13) starts" waitf 10 g02_runsis N13 1
waitf 5 grep -qF "node N13 run 1 /noodlebot:node N13 | $g02_wt/N13 | node/N13-omicron" "$G02_GD/claude.log"   # setup: the log line is written just after the run is counted
ok "G02-AC-1: that N13 session runs in worktrees/<name>/N13 on its branch" grep -qF "node N13 run 1 /noodlebot:node N13 | $g02_wt/N13 | node/N13-omicron" "$G02_GD/claude.log"
waitf 5 grep -qF "node N14 run 1 /noodlebot:node N14 | $g02_wt/N14 |" "$G02_GD/claude.log"   # setup: the log line is written just after the run is counted
ok "G02-AC-1: and that N14 session runs in worktrees/<name>/N14" grep -qF "node N14 run 1 /noodlebot:node N14 | $g02_wt/N14 |" "$G02_GD/claude.log"
g02_stop


loop_end
